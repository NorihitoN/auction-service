module Main where

import Client.Session
import Control.Exception.Safe (SomeException, try)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (asks)
import Control.Monad.Trans (lift)
import Data.Text (pack)
import Data.UUID (fromString, toString)
import Domain.Types
import Network.HTTP.Client (Manager, defaultManagerSettings, newManager)
import System.Console.Haskeline
  ( InputT,
    defaultSettings,
    getInputLine,
    outputStrLn,
    runInputT,
  )

type AuctionClient = AuctionSessionT (InputT IO)

putLn :: (MonadIO m) => String -> m ()
putLn = liftIO . Prelude.putStrLn

main :: IO ()
main = do
  manager <- newManager defaultManagerSettings
  let url = "http://localhost:8080"
  runInputT defaultSettings (outerLoop manager url)

outerLoop :: Manager -> String -> InputT IO ()
outerLoop manager url = do
  outputStrLn "=== Auction Service ==="
  outputStrLn "  /signup <name>     - Create new account"
  outputStrLn "  /signin <user-id>  - Sign in with UUID"
  outputStrLn "  /quit              - Exit"
  go
  where
    go = do
      mLine <- getInputLine "> "
      case mLine of
        Nothing -> outputStrLn "Goodbye!"
        Just input -> case words input of
          ["/quit"] -> outputStrLn "Goodbye!"
          ["/signup", name] -> do
            result <- liftIO $ try $ evalAuctionOnClient manager url (RegisterUser (NewUser (pack name) (Price 10000)))
            case result of
              Left err -> outputStrLn $ "Error: " <> show (err :: SomeException)
              Right uid -> do
                outputStrLn $ "Registered! Your UserId: " <> toString (unUserId uid)
                enterSession manager url uid
            go
          ["/signin", uidStr] -> case fromString uidStr of
            Nothing -> outputStrLn "Invalid UUID format" >> go
            Just uuid -> do
              enterSession manager url (UserId uuid)
              go
          _ -> outputStrLn "Unknown command. Try /signup <name>, /signin <uuid>, or /quit" >> go

enterSession :: Manager -> String -> UserId -> InputT IO ()
enterSession manager url uid = do
  let env = AuctionEnv manager url uid
  runAuctionSession env auctionRepl

auctionRepl :: AuctionClient ()
auctionRepl = do
  putLn "\n--- Logged in. Type /help for commands, /logout to return ---"
  go
  where
    go = do
      mLine <- lift $ getInputLine "auction> "
      case mLine of
        Nothing -> return ()
        Just input -> case words input of
          ["/logout"] -> putLn "Logged out."
          ["/help"] -> showHelp >> go
          ["/whoami"] -> handleWhoami >> go
          ("/item" : rest) -> handleRegisterItem rest >> go
          ("/sell" : rest) -> handleSell rest >> go
          ("/view" : rest) -> handleView rest >> go
          ("/bid" : rest) -> handleBid rest >> go
          [] -> go
          _ -> putLn "Unknown command. Type /help" >> go

showHelp :: AuctionClient ()
showHelp = do
  putLn "  /whoami                          - Show current user info"
  putLn "  /item <name> <description>       - Register an item"
  putLn "  /sell <item-id> <price>          - Sell item to auction"
  putLn "  /view <auction-id>               - View an auction"
  putLn "  /bid <auction-id> <price>        - Place a bid"
  putLn "  /logout                          - Return to main menu"
  putLn "  /help                            - Show this help"

handleWhoami :: AuctionClient ()
handleWhoami = do
  uid <- AuctionSessionT $ asks sessionUserId
  result <- try $ checkUser uid
  case result of
    Left err -> putLn $ "Error: " <> show (err :: SomeException)
    Right Nothing -> putLn $ "User not found: " <> toString (unUserId uid)
    Right (Just user) -> do
      putLn $ "  Name:      " <> show (userName user)
      putLn $ "  Money:     " <> show (unPrice (userMoney user))
      putLn $ "  ID:        " <> toString (unUserId (userId user))
      putLn $ "  Inventory: " <> show (userInventory user)

handleRegisterItem :: [String] -> AuctionClient ()
handleRegisterItem (name : descWords) = do
  uid <- AuctionSessionT $ asks sessionUserId
  let desc = unwords descWords
  result <- try $ registerItem uid (NewItem (pack name) (pack desc))
  case result of
    Left err -> putLn $ "Error: " <> show (err :: SomeException)
    Right item -> do
      putLn $ "Item registered: " <> show (itemName item)
      putLn $ "  ID: " <> toString (unItemId (itemId item))
handleRegisterItem _ = putLn "Usage: /item <name> <description>"

handleSell :: [String] -> AuctionClient ()
handleSell [itemIdStr, priceStr] = case (fromString itemIdStr, readMaybe priceStr) of
  (Just iid, Just p) -> do
    uid <- AuctionSessionT $ asks sessionUserId
    result <- try $ sellToAuction uid (ItemId iid) defaultTerm (Price p)
    case result of
      Left err -> putLn $ "Error: " <> show (err :: SomeException)
      Right ai -> do
        putLn "Listed on auction!"
        putLn $ "  Auction ID: " <> toString (unAuctionItemId (auctionItemId ai))
        putLn $ "  Price: " <> show (unPrice (currentPrice ai))
  _ -> putLn "Usage: /sell <item-uuid> <price>"
handleSell _ = putLn "Usage: /sell <item-uuid> <price>"

handleView :: [String] -> AuctionClient ()
handleView [aidStr] = case fromString aidStr of
  Nothing -> putLn "Invalid UUID"
  Just aid -> do
    result <- try $ viewAuctionItem (AuctionItemId aid)
    case result of
      Left err -> putLn $ "Error: " <> show (err :: SomeException)
      Right Nothing -> putLn "Auction not found"
      Right (Just ai) -> do
        putLn $ "  Auction ID: " <> toString (unAuctionItemId (auctionItemId ai))
        putLn $ "  Item: " <> show (itemName (auctionTargetItem ai))
        putLn $ "  Current Price: " <> show (unPrice (currentPrice ai))
        putLn $ "  Bidder: " <> maybe "none" (toString . unUserId) (currentBidderId ai)
handleView _ = putLn "Usage: /view <auction-uuid>"

handleBid :: [String] -> AuctionClient ()
handleBid [aidStr, priceStr] = case (fromString aidStr, readMaybe priceStr) of
  (Just aid, Just p) -> do
    uid <- AuctionSessionT $ asks sessionUserId
    result <- try $ bid uid (AuctionItemId aid) (Price p)
    case result of
      Left err -> putLn $ "Error: " <> show (err :: SomeException)
      Right ai -> do
        putLn "Bid placed!"
        putLn $ "  Current Price: " <> show (unPrice (currentPrice ai))
  _ -> putLn "Usage: /bid <auction-uuid> <price>"
handleBid _ = putLn "Usage: /bid <auction-uuid> <price>"

readMaybe :: (Read a) => String -> Maybe a
readMaybe s = case reads s of
  [(x, "")] -> Just x
  _ -> Nothing

defaultTerm :: Term
defaultTerm =
  Term
    { startTime = read "2026-07-14 00:00:00 UTC",
      endTime = read "2026-07-21 00:00:00 UTC"
    }
