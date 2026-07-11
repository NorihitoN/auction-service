module App.Supervisor where

import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Concurrent.STM (TQueue, atomically, writeTQueue)
import Control.Exception (finally, mask)
import Data.Text (Text)
import qualified Data.Text as T

-- ============================================================
-- supervisor — ワーカーの監視・再起動
--
--   1. ワーカーを起動する
--   2. ワーカーから発生した例外を補足して再起動する
--   3. 非同期例外（外部からのキャンセル）は再起動せず終了する
--   4. ログメッセージを失わない
-- ============================================================

supervisor :: TQueue Text -> IO () -> IO ()
supervisor queue action = do
  atomically $ writeTQueue queue "SUPERVISOR: launch worker"
  loop
  where
    loop = do
      result <- mask $ \restore -> do
        result <- do
          as <- async (restore action)
          waitCatch as `finally` cancel as
        case result of
          Left e  -> atomically $ writeTQueue queue $
            "SUPERVISOR: catch exception: " <> T.pack (show e)
          Right _ -> return ()
        return result
      case result of
        Left _  -> do
          atomically $ writeTQueue queue "SUPERVISOR: re-launch worker"
          loop
        Right _ -> return ()

