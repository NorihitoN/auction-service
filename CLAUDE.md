# Auction Service — CLAUDE.md

## プロジェクト概要

Haskell製オークションサービス。サーバ（Servant + STM）とクライアント（HTTP CLI）に分離。
学習テーマ：型駆動設計・並行システム（STM）・モナド変換子。

## コマンド

```bash
cabal build              # ビルド
cabal build all          # サーバ・クライアント両方
cabal test               # テスト実行
cabal test --test-show-details=streaming  # テスト詳細表示
cabal run auction-server # サーバ起動（ポート8080）
cabal run auction-client -- <subcommand>  # クライアントCLI
cabal repl               # GHCi
```

## アーキテクチャ

```
Client (HTTP) → API Layer (Servant) → App Layer (AppM) → State (STM/TVar)
```

### モナドスタック

```haskell
type AppM = ReaderT AppEnv (ExceptT AppError IO)
```

- `ReaderT AppEnv` — 環境（AppState等）の注入
- `ExceptT AppError` — ドメインエラーの型安全な伝播
- `IO` — 副作用の基底

### レイヤー構成

```
src/Domain/   — 型定義・エラーADT（外部依存なし）
src/App/      — AppM・AppEnv定義
src/State/    — STMベースのインメモリ状態・操作関数
src/Api/      — Servant API型・ハンドラ
app/Main.hs   — サーバ起動
app/Client.hs — HTTPクライアントCLI
test/         — hspec・QuickCheckテスト
```

## コーディング規約

### 型設計
- IDは必ず `newtype` でラップする（`UserId`, `ItemId`, `AuctionId`, `BidId`, `Price`）
- エラーは `AppError` ADTに集約し、`ExceptT` で伝播
- 部分関数（`head`, `tail`, `fromJust`）は使用禁止。`Maybe`/`Either` で安全に扱う

### 並行処理
- 共有状態は `TVar` に閉じ込め、変更は必ず `STM` トランザクション内で行う
- 入札処理は `atomically` で競合を排除する

### Handler
- Handler から直接 `IO` を呼ばない。必ず `AppM` アクションを経由する
- ビジネスロジックは Handler に書かず、`src/State/` または `src/App/` に分離する

## 開発フロー

```
Plan Mode（設計・調査）
  → 実装（Hook が自動で cabal build）
  → 自己検証（cabal test / curl スモークテスト）
  → /code-review
  → PR作成
  → 学びをこのファイルに反映
```

## 禁止事項（Claude へ）

- `fromJust`, `head`, `tail` などの部分関数を使わない
- Handler 内に `IO` アクションを直書きしない
- `TVar` の中身を `STM` の外で変更しない
- `cabal test` が通らない状態でコミットしない
