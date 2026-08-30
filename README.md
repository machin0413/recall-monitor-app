# リコール監視アプリ

廃止された JASPA「リコール情報検索」アプリの代替として、**国土交通省のリコール情報から自分の車両に該当するリコールを自動でお知らせする iOS アプリ**です。

## アーキテクチャ

アプリが国土交通省の検索 API を**直接**呼びます。中間のデータ配信サーバーは持ちません。

```
国土交通省 renrakuda 検索API
   │  GET https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi
   │      ?blog_id=4&class=recalldatacar&model_name=DAA-ZVW50&…
   │  → 型式で絞り込んだ JSON（型式指定なら 5 件 / 40KB / 約 4 秒）
   ▲
   │  ① 起動時・「調べる」実行時・BGAppRefreshTask（8時間後以降OSが実行）
   │
iOS アプリ（SwiftUI）
   │  車台番号の範囲判定は端末側（RecallMatcher）
   │  → 新規該当リコールをローカル通知
   │
   │  ② 起動時に 1 日 1 回だけ設定を取得
   ▼
GitHub Pages（config.json / 数百バイト）
   └── エンドポイントURL・パラメータ名・フィールド接頭辞

GitHub Actions（毎日 07:20 JST）
   └── カナリア: API の生存とスキーマを検査 → 壊れていたら Issue を立てる
```

### なぜこの構成か

当初は「毎日サーバーで全件取得して静的 JSON を配信し、アプリはそれを読む」設計でした。実 API を調べた結果、**型式で絞り込める JSON API** だと分かったため、直接方式に変更しています。

- 全 10,520 件（数十 MB）を配る必要がなくなった
- 「調べる」画面が**事前ダウンロードなし**で使える
- データ配信の 1 日遅れが無くなった

直接方式の弱点は、**仕様変更で全端末が同時に壊れ、App Store 審査を通すまで直せない**ことです。実際この開発中、エンドポイントのパスを 1 階層間違えただけで、サーバーはエラーではなく **HTTP 200 + 本文 0 バイト**を返しました。エラーにならないため気づきにくい種類の壊れ方です。

対策として、**設定だけをリモートに置いています**。

- `site/config.json` を直せば、アプリを更新せずに全端末が復旧する
- カナリアが毎日検査するので、ユーザーからの報告より先に気づける

## 構成

```
recall-monitor-app/
├── backend/
│   ├── check_api.py        # カナリア: API の生存・スキーマ検査
│   ├── matching.py         # 照合ロジックの参照実装（Swift 側と同一仕様）
│   ├── test_matching.py    # 照合ロジックのテスト（実データの車台番号範囲を使用）
│   └── requirements.txt    # 標準ライブラリのみ
├── .github/workflows/
│   └── check-api.yml       # 毎日カナリア実行 → 失敗時に Issue、成功時に config.json を公開
├── site/
│   ├── config.json         # アプリが読むリモート設定
│   └── index.html          # 公開ページ
├── project.yml             # XcodeGen のプロジェクト定義（.xcodeproj は生成物）
├── scripts/build.sh        # xcodegen generate → シミュレータ向けビルド
└── ios/RecallMonitor/      # Xcode プロジェクトに組み込む SwiftUI ソース一式
    ├── RecallMonitorApp.swift
    ├── Models/             # Vehicle / Recall（API レスポンスのモデル）
    ├── Services/           # RemoteConfig / API クライアント / 照合 / 通知 / バックグラウンド更新
    ├── ViewModels/         # VehicleStore / RecallMonitorStore
    ├── Views/              # 調べる・マイカー・リコール・詳細・設定
    └── Info.plist          # BGTaskScheduler 設定ほか
```

## 画面

| タブ | 役割 |
| --- | --- |
| 調べる | 車両を登録せずに型式・車台番号で照合。型式だけでも検索できる |
| マイカー | 登録車両と該当件数。定期確認オフの車両はベルに斜線が付く |
| リコール | 登録車両に該当する届出の一覧 |
| 設定 | 定期確認の全体スイッチ、手動更新、アプリ情報 |

## 照合の考え方

安全に関わる情報なので、**取りこぼしを避ける方向に倒しています**。

- API の `model_name` は部分一致なので、**型式の確定判定は端末側**で行う
- 型式が一致した届出は必ず拾う
- 車台番号が範囲内だと確認できたときだけ「**対象**」（オレンジの △）
- 範囲を判定できないときは「**要確認**」（黄色の ?）として残し、通知の文面でも区別する
- すべての範囲が「範囲外」と確定した型式レコードだけを除外する

1 つの型式に**不連続な複数の範囲**が入ることがあります（例: `ZVW50-6000001〜6118168` と `ZVW50-8000001〜8077900`）。範囲の隙間（`ZVW50-7000000` など）を対象にしないよう、範囲ごとに判定します。

車台番号は区切りの有無どちらでも受け付けます。`ZVW506000001` のように区切りが無い場合、型式にも数字が含まれるため単純な分割では誤判定するので、**届出側のプレフィックスを削って**連番を取り出します。

仕様は `backend/matching.py` に参照実装として書き出し、`backend/test_matching.py` で守っています。`ios/.../RecallMatcher.swift` を変更したら**両方を同期してください**。

## 定期確認のオン/オフ

2 段階で切れます。どちらをオフにしても**一覧・詳細の該当表示は残り、通知だけが止まります**。

- **車両ごと** — 車両の編集画面のトグル（`Vehicle.monitoringEnabled`）
- **全体** — 設定のトグル。オフで `BGTaskScheduler.cancel` を呼び、バックグラウンド更新の予約自体を止める

## セットアップ

### 1) 設定の配信（GitHub Pages）

1. リポジトリ設定 → **Actions** が有効なことを確認します。
2. **Actions タブ → check-api → Run workflow** を実行します。カナリアが通ると `site/` が `gh-pages` ブランチに公開されます。
3. リポジトリ設定 → **Pages** → Source: `Deploy from a branch` → `gh-pages/root`。
4. `https://<ユーザー名>.github.io/recall-monitor-app/config.json` が開ければ成功です。

> config.json が取得できなくても、アプリは組み込みの既定値で動作します。

### 2) iOS アプリ

macOS + Xcode が必要です。プロジェクトファイル（`.xcodeproj`）は `project.yml` から生成するため、リポジトリにはコミットしていません（`project.pbxproj` は差分が読めないため）。

```bash
brew install xcodegen     # 初回のみ
./scripts/build.sh        # 生成 → シミュレータ向けビルド
```

`scripts/build.sh` は `xcodegen generate` でプロジェクトを作り、署名なし（`CODE_SIGNING_ALLOWED=NO`）でシミュレータ向けにビルドします。コンパイルが通るかの確認はこれで済みます。

シミュレータや実機で動かす場合:

```bash
xcodegen generate
open RecallMonitor.xcodeproj
```

実機で動かすときは **Signing & Capabilities** で自分のチームを選んでください（`project.yml` の `DEVELOPMENT_TEAM` に Team ID を書いても構いません）。

**Swift ファイルを追加・削除したら `xcodegen generate` を実行し直してください。** プロジェクトはファイル一覧を持っているため、再生成しないと反映されません。

配信元を自分のものに変える場合は `RemoteConfigStore.defaultConfigURL` を書き換えます。

### 3) ローカルでの確認

```bash
cd backend
python3 test_matching.py   # 照合ロジックのテスト
python3 check_api.py       # 実 API の生存・スキーマ検査
```

外部依存パッケージなしの標準ライブラリのみで動作します。

iOS 側のコンパイル確認（macOS のみ）:

```bash
./scripts/build.sh
```

> `check_api.py` は国交省サーバーへ実際に接続します。ネットワークによっては到達できないことがあります（本番の検査は GitHub Actions が行います）。

## メンテナンス

カナリアが失敗すると `api-breakage` ラベルの Issue が立ちます。`site/config.json` を新仕様に合わせて更新すれば、**App Store 更新なしで全端末が復旧します**。

config.json で吸収できるもの:

- エンドポイント URL（`endpoint`）
- 固定パラメータ（`fixed_params`: `blog_id` / `class` / `order_by` / `order_condition`）
- 可変パラメータ名（`param_names`: `model_name` / `notification_date` / `offset` / `limit`）
- フィールド接頭辞（`field_prefixes`）
- 詳細ページ URL（`detail_url_template`）

レスポンスの構造そのものが変わった場合はアプリ側の修正が必要です。

## 将来拡張（APNs リモート通知）

ローカル通知はアプリが起動またはバックグラウンド更新したタイミングでの検出です。即時プッシュが欲しい場合は、新着届出を監視して APNs/FCM へ送るジョブを追加し、アプリに `aps-environment` entitlement とリモート通知の受信処理を足します。個人開発の規模ならローカル通知で十分という判断を推奨します。

## 免責

データ仕様は 2026-08 時点の国土交通省サイトを基にしています。サイト改修により変わり得ます。

車台番号の範囲に入っていても、仕様（変速機の違い、ターボの有無等）により対象外の場合があります。最終的な確認は必ず自動車メーカーまたは販売会社にお問い合わせください。
