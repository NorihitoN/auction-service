{-# LANGUAGE GADTs #-}

module State.AppState where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( STM, TMVar, TVar
  , atomically, modifyTVar', newEmptyTMVarIO, newTVarIO, newTVar
  , putTMVar, readTVar, readTVarIO, takeTMVar, tryReadTMVar, tryTakeTMVar
  , writeTVar, writeTQueue, throwSTM
  , TQueue
  )
import Control.Exception (throwIO)
import Control.Monad (void)
import qualified Data.HashMap.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import qualified Data.UUID.V4 as UUID

import Domain.Error (AppError (..))
import Domain.Types

-- ============================================================
-- AuctionItem' — サーバ内部表現（TVar で並行制御）
-- ============================================================

data AuctionItem' = AuctionItem'
  { auctionItem'Id           :: AuctionItemId
  , auctionItem'Seller       :: TVar User
  , auctionItem'CurrentPrice :: Price
  , auctionItem'CurrentUser  :: Maybe (TVar User)
  , auctionItem'Term         :: Term
  , auctionItem'TargetItem   :: Item
  }

-- AuctionItem'（内部）→ AuctionItem（外部公開用）のスナップショット変換
toAuctionItem :: AuctionItem' -> STM AuctionItem
toAuctionItem ai = do
  seller       <- readTVar (auctionItem'Seller ai)
  mCurrentUser <- mapM readTVar (auctionItem'CurrentUser ai)
  return AuctionItem
    { auctionItemId     = auctionItem'Id ai
    , sellerId          = userId seller
    , currentPrice      = auctionItem'CurrentPrice ai
    , currentBidderId   = fmap userId mCurrentUser
    , auctionTerm       = auctionItem'Term ai
    , auctionTargetItem = auctionItem'TargetItem ai
    }

-- ============================================================
-- AuctionState — STM ベースのインメモリ状態
-- ============================================================

data AuctionState = AuctionState
  { registeredUsers    :: TVar (M.HashMap UserId (TVar User))
  , registeredItems    :: TVar (M.HashMap ItemId Item)
  , currentAuctionItem :: TMVar AuctionItem'
  }

newAuctionState :: IO AuctionState
newAuctionState = AuctionState
  <$> newTVarIO M.empty
  <*> newTVarIO M.empty
  <*> newEmptyTMVarIO

-- ============================================================
-- ヘルパー
-- ============================================================

getUser :: AuctionState -> UserId -> IO (TVar User)
getUser state uid = do
  users <- readTVarIO (registeredUsers state)
  case M.lookup uid users of
    Just tUser -> return tUser
    Nothing    -> throwIO UserNotFound

getItem :: AuctionState -> ItemId -> IO Item
getItem state iid = do
  items <- readTVarIO (registeredItems state)
  case M.lookup iid items of
    Just item -> return item
    Nothing   -> throwIO ItemNotFound

-- ユーザを更新する。userId が変わっていたら InvalidUserUpdate
updateUser :: TVar User -> (User -> User) -> STM ()
updateUser tUser f = do
  old <- readTVar tUser
  let new = f old
  if userId new == userId old
    then writeTVar tUser new
    else throwSTM InvalidUserUpdate

-- ユーザにアイテムを追加する
addItemToUser :: TVar User -> Item -> STM ()
addItemToUser tUser item =
  updateUser tUser $ \u ->
    u { userInventory = addItem (userInventory u) item }

-- ============================================================
-- evalAuction — GADT インタープリタ
-- ============================================================

evalAuction :: AuctionState -> Auction a -> IO a

evalAuction state (RegisterUser newUser) = do
  newId <- UserId <$> UUID.nextRandom
  tUser <- newTVarIO User
    { userId        = newId
    , userName      = newUserName newUser
    , userMoney     = newUserMoney newUser
    , userInventory = Inventory []
    }
  atomically $ modifyTVar' (registeredUsers state) (M.insert newId tUser)
  return newId

evalAuction state (CheckUser uid) = do
  users <- readTVarIO (registeredUsers state)
  case M.lookup uid users of
    Nothing    -> return Nothing
    Just tUser -> Just <$> readTVarIO tUser

evalAuction state (RegisterItem uid newItem) = do
  _ <- getUser state uid
  newId <- ItemId <$> UUID.nextRandom
  let item = Item
        { itemId          = newId
        , itemName        = newItemName newItem
        , itemDescription = newItemDescription newItem
        }
  atomically $ modifyTVar' (registeredItems state) (M.insert newId item)
  return item

evalAuction state (SellToAuction uid iid term startPrice) = do
  tSeller     <- getUser state uid
  item        <- getItem state iid
  currentTime <- getCurrentTime
  if endTime term <= currentTime
    then throwIO InvalidTerm
    else if unPrice startPrice < 0
      then throwIO InvalidPrice
      else do
        newAid <- AuctionItemId <$> UUID.nextRandom
        let ai' = AuctionItem'
              { auctionItem'Id           = newAid
              , auctionItem'Seller       = tSeller
              , auctionItem'CurrentPrice = startPrice
              , auctionItem'CurrentUser  = Nothing
              , auctionItem'Term         = term
              , auctionItem'TargetItem   = item
              }
        atomically $ do
          mExisting <- tryReadTMVar (currentAuctionItem state)
          case mExisting of
            Just _  -> throwSTM AuctionItemAlreadyExist
            Nothing -> do
              putTMVar (currentAuctionItem state) ai'
              toAuctionItem ai'

evalAuction state (ViewAuctionItem aid) =
  atomically $ do
    mAi' <- tryReadTMVar (currentAuctionItem state)
    case mAi' of
      Nothing  -> return Nothing
      Just ai' ->
        if auctionItem'Id ai' == aid
          then Just <$> toAuctionItem ai'
          else return Nothing

evalAuction state (Bid uid aid bidPrice) = do
  tBidder     <- getUser state uid
  currentTime <- getCurrentTime
  atomically $ do
    mAi' <- tryReadTMVar (currentAuctionItem state)
    case mAi' of
      Nothing  -> throwSTM AuctionNotFound
      Just ai' -> do
        if auctionItem'Id ai' /= aid
          then throwSTM AuctionNotFound
          else do
            let term = auctionItem'Term ai'
            if currentTime < startTime term || endTime term <= currentTime
              then throwSTM AuctionClosed
              else if bidPrice <= auctionItem'CurrentPrice ai'
                then throwSTM BidTooLow
                else do
                  seller <- readTVar (auctionItem'Seller ai')
                  if userId seller == uid
                    then throwSTM SellerCannotBid
                    else do
                      bidder <- readTVar tBidder
                      if userMoney bidder < bidPrice
                        then throwSTM NotEnoughMoney
                        else do
                          _ <- takeTMVar (currentAuctionItem state)
                          let ai'' = ai'
                                { auctionItem'CurrentPrice = bidPrice
                                , auctionItem'CurrentUser  = Just tBidder
                                }
                          putTMVar (currentAuctionItem state) ai''
                          toAuctionItem ai''

-- ============================================================
-- facilitator — オークション終了タイマー（1秒ごとにチェック）
-- ============================================================

facilitator :: TQueue Text -> AuctionState -> IO ()
facilitator queue state = loop
  where
    loop = do
      threadDelay (1000 * 1000)
      handleFinishedAuctionItem queue state
      loop

handleFinishedAuctionItem :: TQueue Text -> AuctionState -> IO ()
handleFinishedAuctionItem queue state = do
  currentTime <- getCurrentTime
  atomically $ do
    mAi' <- tryReadTMVar (currentAuctionItem state)
    case mAi' of
      Nothing  -> writeTQueue queue "FACILITATOR: Auction doesn't hold"
      Just ai' ->
        if currentTime < endTime (auctionItem'Term ai')
          then writeTQueue queue "FACILITATOR: Auction holds"
          else do
            void $ takeTMVar (currentAuctionItem state)
            case auctionItem'CurrentUser ai' of
              Just tWinner -> do
                -- winner の所持金を減らしアイテムを渡す
                updateUser tWinner $ \w -> w
                  { userInventory = addItem (userInventory w) (auctionItem'TargetItem ai')
                  , userMoney     = Price (unPrice (userMoney w) - unPrice (auctionItem'CurrentPrice ai'))
                  }
                -- seller の所持金を増やす
                updateUser (auctionItem'Seller ai') $ \s -> s
                  { userMoney = Price (unPrice (userMoney s) + unPrice (auctionItem'CurrentPrice ai'))
                  }
                writeTQueue queue "FACILITATOR: Auction finished successfully"
              Nothing -> do
                -- 入札者なし → seller にアイテムを返す
                addItemToUser (auctionItem'Seller ai') (auctionItem'TargetItem ai')
                writeTQueue queue "FACILITATOR: Auction finished with no bidder"

