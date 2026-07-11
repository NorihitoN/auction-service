{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoMonoLocalBinds #-}

module Main where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (Exception, throwIO)
import Data.Aeson (FromJSON, ToJSON, defaultOptions, eitherDecode, encode, object, (.=))
import Data.Aeson.TH (deriveJSON)
import Data.Data (Typeable)
import Network.HTTP.Client (Manager, RequestBody (..), defaultManagerSettings, httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseStatus)
import Network.HTTP.Types (status200, status400)
import Network.Wai (Application, lazyRequestBody, responseLBS)
import Network.Wai.Handler.Warp (Port, defaultSettings, runSettings, setBeforeMainLoop, setPort)

-- ============================================================
-- 1. Domain — GADT（外部ライブラリに依存しない）
--
--   Counter a の型引数 a がコマンドの返り値型を「宣言」する。
--   この GADT がシステム全体の型レベル API 仕様書になる。
--   Add :: Counter Int  → 実行すると Int が返る
--   Reset :: Counter () → 実行すると () が返る
-- ============================================================

data Counter a where
  Add :: Int -> Counter Int
  Reset :: Counter ()

-- ============================================================
-- 2. State — STM ベースのインメモリ状態（STM のみ依存）
--
--   evalCounterServer が GADT を解釈して TVar を操作する。
--   aeson / wai への依存はゼロ。
--   ライブラリを差し替えてもこの層は変わらない。
-- ============================================================

newtype CounterState = CounterState {counter :: TVar Int}

newCounterState :: Int -> IO CounterState
newCounterState n = CounterState <$> newTVarIO n

evalCounterServer :: CounterState -> Counter a -> IO a
evalCounterServer state (Add n) = atomically $ do
  m <- readTVar (counter state)
  writeTVar (counter state) (m + n)
  return (m + n)
evalCounterServer state Reset =
  atomically $ writeTVar (counter state) 0

-- ============================================================
-- 3. JSON Bridge — Wire 型（aeson に依存、ドメインに非依存）
--
--   CounterRequest / CounterWireResp は HTTP の外部表現。
--   ドメインの Counter GADT とは別に定義し、
--   ドメインを aeson から切り離す。
--   JSON ライブラリを替えてもドメイン層は影響を受けない。
-- ============================================================

data CounterRequest = AddReq Int | ResetReq deriving (Show)

data CounterWireResp = ValueResp Int | OkResp deriving (Show)

deriveJSON defaultOptions ''CounterRequest
deriveJSON defaultOptions ''CounterWireResp

-- handler: CounterRequest → GADT → evalCounterServer → CounterWireResp
handleRequest :: CounterState -> CounterRequest -> IO CounterWireResp
handleRequest state (AddReq n) = ValueResp <$> evalCounterServer state (Add n)
handleRequest state ResetReq = OkResp <$ evalCounterServer state Reset

-- ============================================================
-- 4. CounterResponse GADT — 型引数付きレスポンス（aeson 非依存）
--
--   CounterResponse a の a が返り値の型を保証する。
--   unwrapResponse は GADT のおかげで全域関数になる：
--   - AddResp ブランチ  → a ~ Int  が確定 → v :: Int を返す
--   - ResetResp ブランチ → a ~ () が確定 → () を返す
--   部分関数が不要になるのが GADT を使う利点。
-- ============================================================

data CounterResponse a where
  AddResp :: Int -> CounterResponse Int
  ResetResp :: CounterResponse ()

-- 全域関数：各ブランチで a が確定するため網羅的
unwrapResponse :: CounterResponse a -> a
unwrapResponse (AddResp v) = v
unwrapResponse ResetResp = ()

-- ============================================================
-- 5. jsonServer — 汎用 JSON API ファクトリ（wai に依存）
--
--   (req -> IO resp) を受け取り WAI Application を返す。
--   ルーティングを知らず decode / encode だけ担当する。
--   handler を差し替えるだけで別ドメインにも使い回せる。
-- ============================================================

jsonServer :: (FromJSON req, ToJSON resp) => (req -> IO resp) -> Application
jsonServer handler req respond = do
  body <- lazyRequestBody req
  case eitherDecode body of
    Left err ->
      respond $
        responseLBS
          status400
          [("Content-Type", "application/json")]
          (encode $ object ["error" .= err])
    Right r -> do
      resp <- handler r
      respond $
        responseLBS
          status200
          [("Content-Type", "application/json")]
          (encode resp)

-- ============================================================
-- 6. counterServer — サーバ起動
--
--   onReady コールバックを受け取り、起動完了後に呼ぶ。
--   MVar と組み合わせてクライアントと同期できる。
-- ============================================================

counterServer :: Port -> IO () -> IO ()
counterServer port onReady = do
  state <- newCounterState 0
  let settings = setPort port $ setBeforeMainLoop onReady defaultSettings
  putStrLn $ "Counter server running on port " <> show port
  runSettings settings (jsonServer (handleRequest state))

-- ============================================================
-- 7. Client — Counter a → HTTP → a
--
--   evalCounterClient が公開インタフェース。
--   内部実装（HTTP, JSON）を隠蔽し、呼び出し元は
--   Counter GADT だけを知っていれば使える。
--
--   toCounterResponse: wire 型 → CounterResponse GADT に変換。
--   コマンドの型で「どのコンストラクタが来るか」を決定する。
--   unwrapResponse: 全域関数で安全に a を取り出す。
-- ============================================================

type Host = String

newtype CounterError = CounterError String deriving (Show, Typeable)

instance Exception CounterError

-- Wire 型 → CounterResponse GADT（コマンドで型を決定）
toCounterResponse :: Counter a -> CounterWireResp -> Either String (CounterResponse a)
toCounterResponse (Add _) (ValueResp v) = Right (AddResp v)
toCounterResponse Reset OkResp = Right ResetResp
toCounterResponse _ _ = Left "unexpected response shape"

-- HTTP 送信層（Manager は外から注入 — 1回だけ生成して共有）
callCounterApi :: Manager -> Host -> Port -> CounterRequest -> IO CounterWireResp
callCounterApi manager host port req = do
  let url = "http://" <> host <> ":" <> show port
      body = encode req
  baseReq <- parseRequest url
  let request =
        baseReq
          { method = "POST",
            requestBody = RequestBodyLBS body,
            requestHeaders = [("Content-Type", "application/json")]
          }
  res <- httpLbs request manager
  if responseStatus res == status200
    then case eitherDecode @CounterWireResp (responseBody res) of
      Right r -> return r
      Left err -> throwIO $ CounterError ("decode failed: " <> err)
    else throwIO $ CounterError ("HTTP error: " <> show (responseStatus res))

-- 公開インタフェース：呼び出し元は Counter GADT だけ知っていればよい
evalCounterClient :: Manager -> Host -> Port -> Counter a -> IO a
evalCounterClient manager host port cmd = do
  let req :: CounterRequest
      req = case cmd of
        Add n -> AddReq n
        Reset -> ResetReq
  wire <- callCounterApi manager host port req
  case toCounterResponse cmd wire of
    Right resp -> return (unwrapResponse resp)
    Left err -> throwIO $ CounterError err

-- ============================================================
-- 8. main
-- ============================================================

main :: IO ()
main = do
  let port = 8081 :: Port
      host = "localhost"

  -- MVar でサーバ起動完了を確実に待つ
  ready <- newEmptyMVar
  _ <- forkIO $ counterServer port (putMVar ready ())
  takeMVar ready

  -- Manager を1回だけ作成して全リクエストで共有
  manager <- newManager defaultManagerSettings
  let go = evalCounterClient manager host port

  v1 <- go (Add 10)
  print v1
  v2 <- go (Add 5)
  print v2
  go Reset
  putStrLn "Reset"
  v3 <- go (Add 3)
  print v3
