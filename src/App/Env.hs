module App.Env where

import State.AppState (AuctionState)

-- ============================================================
-- AppEnv — アプリケーション全体で共有する環境
--
--   ReaderT AppEnv で全ハンドラに暗黙的に渡される。
--   AuctionState（TVar）を保持する。
-- ============================================================

data AppEnv = AppEnv
  { appState :: AuctionState
  }
