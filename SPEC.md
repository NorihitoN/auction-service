# オークションサービス仕様書

## 1. サービス概要

Haskellで実装するオークションサービス。
サーバが全ロジックを担い、クライアントはHTTP経由で操作を送付するのみ。

---

## 2. ドメインルール

### 出品
- 商品提供者はアイテムに「初期価格」と「オークション期間」を設定して出品する
- 出品されたアイテムは即座にオークション開始状態になる

### 入札
- 入札者は現在の最高入札価格より**厳密に大きい値**でのみ入札できる
- 入札が成功すると現在価格が更新される

### 落札
- オークション期間終了時、最高入札者がその価格で落札する
- 入札者がいない場合は流札とする

---

## 3. エンティティ

### User（ユーザ）
| フィールド   | 型           | 説明               |
|--------------|--------------|--------------------|
| userId       | UserId       | 一意識別子         |
| userName     | Text         | 表示名             |
| email        | Email        | メールアドレス     |
| createdAt    | UTCTime      | 登録日時           |

### Item（アイテム）
| フィールド   | 型           | 説明               |
|--------------|--------------|--------------------|
| itemId       | ItemId       | 一意識別子         |
| sellerId     | UserId       | 出品者             |
| title        | Text         | 商品名             |
| description  | Text         | 商品説明           |
| startPrice   | Price        | 初期価格           |
| createdAt    | UTCTime      | 登録日時           |

### Auction（オークション）
| フィールド     | 型             | 説明                     |
|----------------|----------------|--------------------------|
| auctionId      | AuctionId      | 一意識別子               |
| itemId         | ItemId         | 対象アイテム             |
| startPrice     | Price          | 開始価格                 |
| currentPrice   | Price          | 現在の最高入札価格       |
| highestBidder  | Maybe UserId   | 現在の最高入札者         |
| startAt        | UTCTime        | 開始日時                 |
| endAt          | UTCTime        | 終了日時                 |
| status         | AuctionStatus  | オークション状態         |

### AuctionStatus
```
Open      -- 入札受付中
Closed    -- 落札あり終了
Unsold    -- 流札（入札なし）
```

### Bid（入札）
| フィールド   | 型           | 説明               |
|--------------|--------------|--------------------|
| bidId        | BidId        | 一意識別子         |
| auctionId    | AuctionId    | 対象オークション   |
| bidderId     | UserId       | 入札者             |
| amount       | Price        | 入札額             |
| bidAt        | UTCTime      | 入札日時           |

---

## 4. APIエンドポイント

### ユーザ管理
| メソッド | パス              | 説明             |
|----------|-------------------|------------------|
| POST     | /users            | ユーザ登録       |
| GET      | /users/:userId    | ユーザ情報取得   |

### アイテム管理
| メソッド | パス              | 説明             |
|----------|-------------------|------------------|
| POST     | /items            | アイテム出品     |
| GET      | /items/:itemId    | アイテム情報取得 |
| GET      | /items            | アイテム一覧取得 |

### オークション管理
| メソッド | パス                        | 説明                   |
|----------|-----------------------------|------------------------|
| POST     | /auctions                   | オークション開始       |
| GET      | /auctions/:auctionId        | オークション情報取得   |
| GET      | /auctions                   | オークション一覧       |
| POST     | /auctions/:auctionId/bids   | 入札                   |
| GET      | /auctions/:auctionId/bids   | 入札履歴取得           |

---

## 5. システム構成

```
┌─────────────────────────────┐
│         Client              │
│  (HTTP requests only)       │
└──────────────┬──────────────┘
               │ HTTP
┌──────────────▼──────────────┐
│         Server              │
│  ┌────────────────────────┐ │
│  │   API Layer (Servant)  │ │
│  └──────────┬─────────────┘ │
│  ┌──────────▼─────────────┐ │
│  │  Application Layer     │ │
│  │  (Business Logic)      │ │
│  └──────────┬─────────────┘ │
│  ┌──────────▼─────────────┐ │
│  │  Concurrent State      │ │
│  │  (STM / TVar)          │ │
│  └────────────────────────┘ │
└─────────────────────────────┘
```

---

## 6. 技術スタック（候補）

| 用途             | ライブラリ候補              |
|------------------|-----------------------------|
| Web Framework    | Servant                     |
| 並行制御         | STM (TVar, TChan)           |
| JSON             | aeson                       |
| 時刻             | time                        |
| UUID             | uuid                        |
| HTTPクライアント | http-client / req           |

---

## 7. 技術的注目点

### 型駆動設計
- `newtype` による識別子型（`UserId`, `ItemId`, `AuctionId`, `Price`）
- `AuctionStatus` による状態機械の型レベル表現
- Servant の型レベルAPI定義

### 並行システム
- `TVar` によるオークション状態の並行安全な管理
- `STM` トランザクションで入札の競合を排除
- `async` によるオークション終了タイマー管理

### 言語拡張・モナド変換子
- `ReaderT` による環境（DB・設定）の受け渡し
- `ExceptT` によるエラーハンドリング
- `DataKinds`, `TypeOperators` （Servant APIの型レベル定義）
- `OverloadedStrings`, `DeriveGeneric` 等

---

## 8. エラーケース

| エラー                | 説明                                 |
|-----------------------|--------------------------------------|
| UserNotFound          | 指定ユーザが存在しない               |
| ItemNotFound          | 指定アイテムが存在しない             |
| AuctionNotFound       | 指定オークションが存在しない         |
| AuctionClosed         | すでに終了したオークションへの入札   |
| BidTooLow             | 入札額が現在価格以下                 |
| SellerCannotBid       | 出品者自身による入札                 |
