module Api.Handler.Auction where

import Api.Types
import Control.Exception (catch)
import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode, object, (.=))
import Domain.Types (Auction (..))
import Network.HTTP.Types (status200, status400)
import Network.Wai (Application, lazyRequestBody, responseLBS)
import State.AppState (AuctionState, evalAuction)

-- ============================================================
-- jsonServer — 汎用 JSON API ファクトリ
--
--   Counter.hs と同じ実装をライブラリ側に昇格させたもの。
--   (req -> IO resp) を受け取り WAI Application を返す。
--   decode / encode のみ担当し、ルーティングを知らない。
-- ============================================================

jsonServer :: (FromJSON req, ToJSON resp) => (req -> IO resp) -> Application
jsonServer handler req respond = do
  body <- lazyRequestBody req
  case eitherDecode body of
    Left err ->
      respond $
        responseLBS
          status400
          [("Content-Type", "application/json")]
          (encode $ object ["error" .= err])
    Right r -> do
      resp <- handler r
      respond $
        responseLBS
          status200
          [("Content-Type", "application/json")]
          (encode resp)

-- ============================================================
-- auctionService — wire 型から GADT へ変換し evalAuction を呼ぶ
--
--   AuctionRequest の各コンストラクタを対応する Auction a に変換、
--   evalAuction で実行して AuctionResponse にラップする。
--   evalAuction が throwIO した AppError は AuctionErr で包む。
-- ============================================================

auctionService :: AuctionState -> AuctionServerRequest -> IO AuctionServerResponse
auctionService state (AuctionServerRequest req) =
  (AuctionOk <$> dispatch req) `catch` (return . AuctionErr)
  where
    dispatch :: AuctionRequest -> IO AuctionResponse
    dispatch (RegisterUserReq newUser) =
      RegisterUserResp <$> evalAuction state (RegisterUser newUser)
    dispatch (CheckUserReq uid) =
      CheckUserResp <$> evalAuction state (CheckUser uid)
    dispatch (RegisterItemReq uid newItem) =
      RegisterItemResp <$> evalAuction state (RegisterItem uid newItem)
    dispatch (SellToAuctionReq uid iid term price) =
      SellToAuctionResp <$> evalAuction state (SellToAuction uid iid term price)
    dispatch (ViewAuctionItemReq aid) =
      ViewAuctionItemResp <$> evalAuction state (ViewAuctionItem aid)
    dispatch (BidReq uid aid price) =
      BidResp <$> evalAuction state (Bid uid aid price)
