{-# LANGUAGE TemplateHaskell #-}

module Api.Types where

import Data.Aeson (defaultOptions)
import Data.Aeson.TH (deriveJSON)
import Domain.Types
  ( AuctionItem,
    AuctionItemId,
    Inventory,
    Item,
    ItemId,
    NewItem,
    NewUser,
    Price,
    Term,
    User,
    UserId,
  )
import Domain.Error (AppError)

-- ============================================================
-- JSON シリアライズ — wire 型のインスタンス
--
--   deriveJSON はドメイン型を知らない aeson ブリッジ層。
--   ドメイン型（Domain.Types）に aeson を持ち込まないことで
--   JSON フォーマット変更がドメインに波及しない。
-- ============================================================

deriveJSON defaultOptions ''Price
deriveJSON defaultOptions ''UserId
deriveJSON defaultOptions ''ItemId
deriveJSON defaultOptions ''AuctionItemId
deriveJSON defaultOptions ''Term
deriveJSON defaultOptions ''Item
deriveJSON defaultOptions ''Inventory
deriveJSON defaultOptions ''User
deriveJSON defaultOptions ''AuctionItem
deriveJSON defaultOptions ''NewUser
deriveJSON defaultOptions ''NewItem

data AuctionRequest
  = RegisterUserReq NewUser
  | CheckUserReq UserId
  | RegisterItemReq UserId NewItem
  | SellToAuctionReq UserId ItemId Term Price
  | ViewAuctionItemReq AuctionItemId
  | BidReq UserId AuctionItemId Price

data AuctionResponse
  = RegisterUserResp UserId
  | CheckUserResp (Maybe User)
  | RegisterItemResp Item
  | SellToAuctionResp AuctionItem
  | ViewAuctionItemResp (Maybe AuctionItem)
  | BidResp AuctionItem

newtype AuctionServerRequest = AuctionServerRequest AuctionRequest
data AuctionServerResponse = AuctionOk AuctionResponse | AuctionErr AppError

deriveJSON defaultOptions ''AppError
deriveJSON defaultOptions ''AuctionRequest
deriveJSON defaultOptions ''AuctionResponse
deriveJSON defaultOptions ''AuctionServerRequest
deriveJSON defaultOptions ''AuctionServerResponse
