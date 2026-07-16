{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeApplications #-}

module Client.Session where

import Api.Types
import Control.Exception (Exception, throwIO)
import Control.Exception.Safe (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (ReaderT (..), asks)
import Control.Monad.Trans (MonadTrans)
import Data.Aeson (eitherDecode, encode)
import Data.Typeable (Typeable)
import Domain.Types
import Network.HTTP.Client
  ( Manager,
    RequestBody (..),
    httpLbs,
    method,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types (status200)
import State.AppState (evalAuction)

newtype AuctionClientError = AuctionClientError String
  deriving (Show, Typeable)

instance Exception AuctionClientError

data AuctionEnv = AuctionEnv
  { sessionManager :: Manager,
    sessionUrl :: String,
    sessionUserId :: UserId
  }

-- ============================================================
-- sendAuctionRequest — HTTP トランスポート層
--
--   AuctionRequest を受け取り、HTTP で送って、AuctionResponse を返す。
--   エラーハンドリングもここで行う。呼び出し側は「成功レスポンスだけ」受け取れる。
-- ============================================================

sendAuctionRequest :: Manager -> String -> AuctionRequest -> IO AuctionResponse
sendAuctionRequest manager url req = do
  baseReq <- parseRequest url
  let httpReq =
        baseReq
          { method = "POST",
            requestBody = RequestBodyLBS (encode (AuctionServerRequest req)),
            requestHeaders = [("Content-Type", "application/json")]
          }
  res <- httpLbs httpReq manager
  if responseStatus res /= status200
    then throwIO $ AuctionClientError ("HTTP error: " <> show (responseStatus res))
    else case eitherDecode @AuctionServerResponse (responseBody res) of
      Left err -> throwIO $ AuctionClientError ("decode failed: " <> err)
      Right (AuctionOk resp) -> return resp
      Right (AuctionErr appErr) -> throwIO $ AuctionClientError ("server error: " <> show appErr)

-- ============================================================
-- toAuctionRequest / toResult — GADT ⇔ wire 型の橋渡し
-- ============================================================

toAuctionRequest :: Auction a -> AuctionRequest
toAuctionRequest (RegisterUser nu) = RegisterUserReq nu
toAuctionRequest (CheckUser uid) = CheckUserReq uid
toAuctionRequest (RegisterItem uid ni) = RegisterItemReq uid ni
toAuctionRequest (SellToAuction uid iid t p) = SellToAuctionReq uid iid t p
toAuctionRequest (ViewAuctionItem aid) = ViewAuctionItemReq aid
toAuctionRequest (Bid uid aid price) = BidReq uid aid price

toResult :: Auction a -> AuctionResponse -> Either String a
toResult (RegisterUser _) (RegisterUserResp uid) = Right uid
toResult (CheckUser _) (CheckUserResp mUser) = Right mUser
toResult (RegisterItem _ _) (RegisterItemResp item) = Right item
toResult (SellToAuction _ _ _ _) (SellToAuctionResp ai) = Right ai
toResult (ViewAuctionItem _) (ViewAuctionItemResp mai) = Right mai
toResult (Bid _ _ _) (BidResp ai) = Right ai
toResult _ _ = Left "unexpected response shape"

-- ============================================================
-- evalAuctionOnClient — 3つの部品の接着剤
--
--   Manager -> String -> Auction a -> IO a
--   AuctionSessionT を使わない場面（テスト等）でもこれ単体で使える。
-- ============================================================

evalAuctionOnClient :: Manager -> String -> Auction a -> IO a
evalAuctionOnClient manager url cmd = do
  let wireReq = toAuctionRequest cmd
  wireResp <- sendAuctionRequest manager url wireReq
  case toResult cmd wireResp of
    Right a -> return a
    Left err -> throwIO $ AuctionClientError err

-- ============================================================
-- AuctionSessionT — ReaderT ラッパー
--
--   毎回 manager と url を渡すのを ReaderT で隠蔽する。
-- ============================================================

newtype AuctionSessionT m a where
  AuctionSessionT :: {unSession :: ReaderT AuctionEnv m a} ->
                       AuctionSessionT m a
  deriving (Functor,
            Applicative,
            Monad,
            MonadIO,
            MonadTrans,
            MonadThrow,
            MonadCatch,
            MonadMask)

runAuctionSession :: AuctionEnv -> AuctionSessionT m a -> m a
runAuctionSession env (AuctionSessionT action) = runReaderT action env

-- ============================================================
-- ユーザ向けアクション
-- ============================================================

runCmd :: (MonadIO m) => Auction a -> AuctionSessionT m a
runCmd cmd = AuctionSessionT $ do
  manager <- asks sessionManager
  url <- asks sessionUrl
  liftIO $ evalAuctionOnClient manager url cmd

registerUser :: (MonadIO m) => NewUser -> AuctionSessionT m UserId
registerUser = runCmd . RegisterUser

checkUser :: (MonadIO m) => UserId -> AuctionSessionT m (Maybe User)
checkUser = runCmd . CheckUser

registerItem :: (MonadIO m) => UserId -> NewItem -> AuctionSessionT m Item
registerItem uid = runCmd . RegisterItem uid

sellToAuction :: (MonadIO m) => UserId -> ItemId -> Term -> Price -> AuctionSessionT m AuctionItem
sellToAuction uid iid term price = runCmd (SellToAuction uid iid term price)

viewAuctionItem :: (MonadIO m) => AuctionItemId -> AuctionSessionT m (Maybe AuctionItem)
viewAuctionItem = runCmd . ViewAuctionItem

bid :: (MonadIO m) => UserId -> AuctionItemId -> Price -> AuctionSessionT m AuctionItem
bid uid aid price = runCmd (Bid uid aid price)
