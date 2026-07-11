module App.Logger where

import Control.Concurrent.STM (TQueue, atomically, readTQueue)
import Control.Monad (forever)
import Data.Text (Text)

-- ============================================================
-- logWriter — TQueue からログを読み出して出力する
--
--   facilitator / supervisor が書き込んだメッセージを
--   logfunc（putStrLn 等）に渡し続ける。
-- ============================================================

logWriter :: TQueue Text -> (Text -> IO ()) -> IO ()
logWriter queue logfunc = forever $ do
  msg <- atomically $ readTQueue queue
  logfunc msg
