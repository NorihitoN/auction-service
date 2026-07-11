module App.Monad where

import Control.Exception (catch)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.Reader (ReaderT (..), asks, runReaderT)

import App.Env (AppEnv (..))
import Domain.Error (AppError)
import Domain.Types (Auction)
import State.AppState (evalAuction)

-- ============================================================
-- AppM — アプリケーションのモナドスタック
--
--   ReaderT AppEnv — 環境（AuctionState 等）を暗黙的に渡す
--   ExceptT AppError — ドメインエラーを型安全に伝播する
--   IO              — 副作用の基底
-- ============================================================

type AppM = ReaderT AppEnv (ExceptT AppError IO)

-- AppM を実行して IO (Either AppError a) に降ろす
runAppM :: AppEnv -> AppM a -> IO (Either AppError a)
runAppM env action = runExceptT (runReaderT action env)

-- ============================================================
-- runAuction — evalAuction を AppM から呼ぶ
--
--   evalAuction が throwIO した AppError 例外を
--   ExceptT の Left に変換して AppM に持ち上げる。
-- ============================================================

runAuction :: Auction a -> AppM a
runAuction cmd = do
  state <- asks appState
  -- liftToEither で IO (Either AppError a) にし、ExceptT でスタックに乗せる
  -- lift で ReaderT 層を越えて ExceptT に届ける
  ReaderT $ \_ -> ExceptT (liftToEither (evalAuction state cmd))

-- IO で throwIO された AppError を Either に変換
liftToEither :: IO a -> IO (Either AppError a)
liftToEither io = (Right <$> io) `catch` (return . Left)
