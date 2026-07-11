module Main where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (newTQueueIO)
import Data.Text.IO (putStrLn)
import Network.Wai.Handler.Warp (Port, defaultSettings, runSettings, setBeforeMainLoop, setPort)
import Prelude hiding (putStrLn)

import Api.Handler.Auction (auctionService, jsonServer)
import App.Logger (logWriter)
import App.Supervisor (supervisor)
import State.AppState (facilitator, newAuctionState)

port :: Port
port = 8080

main :: IO ()
main = do
  state <- newAuctionState
  logQ  <- newTQueueIO

  _ <- forkIO $ logWriter logQ putStrLn
  _ <- forkIO $ supervisor logQ (facilitator logQ state)

  let settings =
        setPort port $
        setBeforeMainLoop (putStrLn "auction-server: listening on port 8080") $
        defaultSettings

  runSettings settings (jsonServer (auctionService state))
