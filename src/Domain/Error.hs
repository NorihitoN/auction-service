module Domain.Error where

import Control.Exception (Exception)
import Data.Text (Text)
import Data.Typeable (Typeable)

data AppError
  = UserNotFound
  | ItemNotFound
  | AuctionNotFound
  | AuctionClosed
  | AuctionItemAlreadyExist
  | BidTooLow
  | LowPrice
  | OutOfTerm
  | NoAuctionItem
  | SellerCannotBid
  | InvalidTerm
  | InvalidPrice
  | InvalidUserUpdate
  | NotEnoughMoney
  | NoEnoughMoney
  | BadData Text
  | UnknownError
  deriving (Eq, Show, Typeable)

instance Exception AppError
