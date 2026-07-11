{-# LANGUAGE GADTs #-}

module Domain.Types where

import Data.Hashable (Hashable (..))
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

-- ============================================================
-- ID newtypes — 外部依存ゼロ
-- ============================================================

newtype UserId = UserId {unUserId :: UUID} deriving (Eq, Ord, Show, Generic)

newtype ItemId = ItemId {unItemId :: UUID} deriving (Eq, Ord, Show, Generic)

newtype AuctionItemId = AuctionItemId {unAuctionItemId :: UUID} deriving (Eq, Ord, Show, Generic)

newtype Price = Price {unPrice :: Int} deriving (Eq, Ord, Show, Generic)

instance Hashable UserId where
  hashWithSalt s (UserId uuid) = hashWithSalt s (show uuid)

instance Hashable ItemId where
  hashWithSalt s (ItemId uuid) = hashWithSalt s (show uuid)

-- ============================================================
-- ドメイン型 — 純粋なレコード（TVar 非依存）
-- ============================================================

data Term = Term
  { startTime :: UTCTime,
    endTime :: UTCTime
  }
  deriving (Eq, Show, Generic)

newtype Inventory = Inventory {unInventory :: [Item]} deriving (Eq, Show, Generic)

addItem :: Inventory -> Item -> Inventory
addItem (Inventory items) item = Inventory (item : items)

data User = User
  { userId :: UserId,
    userName :: Text,
    userMoney :: Price,
    userInventory :: Inventory
  }
  deriving (Eq, Show, Generic)

data Item = Item
  { itemId :: ItemId,
    itemName :: Text,
    itemDescription :: Text
  }
  deriving (Eq, Show, Generic)

-- 外部公開用（JSON シリアライズ可能、TVar なし）
data AuctionItem = AuctionItem
  { auctionItemId :: AuctionItemId,
    sellerId :: UserId,
    currentPrice :: Price,
    currentBidderId :: Maybe UserId,
    auctionTerm :: Term,
    auctionTargetItem :: Item
  }
  deriving (Eq, Show, Generic)

-- ============================================================
-- API — GADT（外部依存ゼロ、型引数が返り値型を宣言）
-- ============================================================

data NewUser = NewUser
  { newUserName :: Text,
    newUserMoney :: Price
  }
  deriving (Eq, Show, Generic)

data NewItem = NewItem
  { newItemName :: Text,
    newItemDescription :: Text
  }
  deriving (Eq, Show, Generic)

data Auction a where
  RegisterUser :: NewUser -> Auction UserId
  CheckUser :: UserId -> Auction (Maybe User)
  RegisterItem :: UserId -> NewItem -> Auction Item
  SellToAuction :: UserId -> ItemId -> Term -> Price -> Auction AuctionItem
  ViewAuctionItem :: AuctionItemId -> Auction (Maybe AuctionItem)
  Bid :: UserId -> AuctionItemId -> Price -> Auction AuctionItem
