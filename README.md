# リコール監視アプリ（実装パッケージ）

廃止された JASPA「リコール情報検索」アプリの代替として、**国土交通省のリコール情報から自分の車両に該当するリコールを自動でお知らせする iOS アプリ**です。

過去セッション「リコール監視アプリの実現性とユニーク性に関する相談」「個人開発の車関連アプリのアイデア相談」での設計（データソース特定・取得フロー・ネーミング案）をもとにパッケージ化しました。

## アーキテクチャ（無料で運用する設計）

```
国交省 renrakuda（リコール情報）
   │  ※ mt-search.cgi / mt-estraier.cgi、robots.txt 制限なし（確認済み）
   ▼
GitHub Actions（毎日 07:20 JST 実行）
   │  backend/fetch_recalls.py
   │    = 一覧取得 → 詳細パース → 型式・車台番号範囲の正規化 → 差分検出
   ▼
GitHub Pages（静的 recalls.json を公開）
   ▼
iOS アプリ（SwiftUI）
   │  起動時 + BGAppRefreshTask（8時間後以降OSが実行）
   │  → フィード取得 → 型式・車台番号でマッチング
   ▼
新規該当リコールをローカル通知
   ※ 移行余白: APNs/FCM でリモート通知化も可能（後述）
```

- **データ取得**: 国土交通省「リコール情報」は API/HTML の両方があり、`recalls.json` を毎日生成します。
- **アプリ側**: フィードURLを1つ設定するだけで動作。ユーザーは車検証どおりの型式（例 `DAA-ZVW50`）と車台番号（例 `ZVW50-0001234`）を登録します。
- **通知**: サーバー不要で動くローカル通知をデフォルトに。将来 APNs/FCM に移行して「即時リモート通知」も可能です。

## 構成

```
recall-app/
├── backend/
│   ├── fetch_recalls.py      # 取得・正規化・差分・JSON生成（国交省向け）
│   ├── normalize.py          # 型式/車台番号の正規化・範囲判定（iOS側と同期）
│   ├── requirements.txt      # 標準ライブラリのみ
│   └── sample_recalls.json   # 開発用サンプル（架空データ）
├── .github/workflows/
│   └── fetch-recalls.yml     # 毎日 cron + 手動実行 → gh-pages へデプロイ
├── site/                     # 公開ディレクトリ（recalls.json が置かれる）
└── ios/RecallMonitor/        # Xcode プロジェクトに組み込む SwiftUI ソース一式
    ├── RecallMonitorApp.swift
    ├── Models/               # Vehicle / Recall（フィードスキーマと同期）
    ├── Services/             # マッチング・API取得・通知・バックグラウンド更新
    ├── ViewModels/           # VehicleStore / RecallMonitorStore
    ├── Views/                # マイカー一覧・編集・リコール一覧・詳細・設定
    └── Info.plist            # BGTaskScheduler 設定ほか
```

## セットアップ手順

### 1) データ配信（GitHub Pages）

1. このパッケージを GitHub リポジトリにプッシュします（公開/プライベートどちらでも可）。
2. リポジトリ設定 → **Actions** が有効になっていることを確認します（デフォルトで有効）。
3. 初回の手動実行: リポジトリの **Actions タブ → fetch-recalls → Run workflow** をクリック。`site/recalls.json` が `gh-pages` ブランチとして発行されます。
4. リポジトリ設定 → **Pages** → Source: `Deploy from a branch` → `gh-pages/root` を選択。
5. 公開URLを確認します:
   `https://<ユーザー名>.github.io/<リポジトリ名>/recalls.json`
6. 動作確認: ブラウザでそのURLを開き JSON が表示されれば成功です。

> **注意**: GitHub Pages は反映に数分かかります。また初回はサーバーのキャッシュで古いデータが返ることがあります。

### 2) iOS アプリ

1. Xcode で **New → App**（SwiftUI、iOS 17+、任意の Bundle ID 例 `jp.recallmonitor.app`）を作成します。
2. `ios/RecallMonitor/` 内の全 Swift ファイルを置き換え/追加します（`ContentView.swift` などと同名の自動生成ファイルは上書き）。
3. Target → **Info** タブで `Info.plist` の内容（BGTaskSchedulerPermittedIdentifiers / UIBackgroundModes）を追加します（プロジェクト生成時に自動で Info 設定があるため、ファイルを直接使う場合は注意）。
4. ターゲットの **Signing & Capabilities** で利用するチームを選択します（実機テスト時）。
5. 起動後、**設定タブ**のフィードURLを GitHub Pages の URL に差し替えます。
6. シミュレータ/実機で「今すぐ更新」→ リコール一覧と、車両登録後の該当表示を確認します。

### 3) ローカルでデータ基盤を試す（開発時）

```bash
cd backend
python3 fetch_recalls.py --headless-mode   # サンプルデータから site/recalls.json を生成
python3 fetch_recalls.py                   # 本番（ネットから国交省データを取得）
```

外部依存パッケージなしの標準ライブラリのみで動作します。

## 国交省データのメンテナンス

- サイト構造（HTML テーブル・API レスポンス）が変更された場合は、`backend/fetch_recalls.py` の `fetch_listing()` / `parse_detail_html()` を更新してください。エラーが起きた場合、GitHub Actions のログに警告が出ます（サンプルで代替するフォールバック付き）。
- 型式・車台番号の判定ロジックは `backend/normalize.py` と `ios/.../RecallMatcher.swift` の**両方**に同じ仕様で実装しています。変更時は両方同期してください。

## ネーミング

前回の相談の残骸として「**リコピコ**」「nenpico 統合」「リコドキ」などの案がありました。`Info.plist` やアプリ内の表示名は用途に合わせて変更できます。

## 将来拡張（APNs リモート通知）

ローカル通知はアプリが起動/バックグラウンド更新したタイミングでの検出です。**即時プッシュ**が欲しい場合は:

1. `GitHub Actions` 上で新規リコール検出時に APNs（または FCM）へ送信するジョブを追加（`.github/workflows/fetch-recalls.yml` に雛形コメントあり）。
2. アプリに `aps-environment` entitlement と `UNUserNotificationCenter` のデリゲート（リモート通知受信）を追加。

個人開発の規模ならローカル通知で十分、という判断を推奨します。

## 免責

本パッケージのデータ仕様・セレクタは 2026-08 時点の国交省サイトを基にしたもので、サイト改修により変わり得ます。動作確認は必ず行ってください。
