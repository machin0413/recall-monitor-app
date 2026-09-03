# リコール監視アプリ

廃止された JASPA「リコール情報検索」アプリの代替となる iOS アプリです。

**車検証の型式を入れれば、登録なしでその場でリコールを調べられます。** マイカーとして登録すれば、新しく該当するリコールが出たときに通知します。

## 設計方針

**検索が主動線です。** 思い立って一度だけ調べる人が大半を占める、という前提で作っています。マイカー登録は「継続して通知を受け取りたい人だけの任意ステップ」であり、必須にしていません。起動するといきなり検索画面が出ます。

**データは端末に持ちません。** 検索のたびに国土交通省のリコール情報検索 API へ問い合わせます。常に最新が返り、古いデータが端末に残りません。国交省側が落ちていれば検索もできませんが、それは正直にエラーとして表示します。

**判定は見逃しより誤検知に倒します。** リコールは「対象外です」と誤って言い切ったときの実害が大きいため、判断がつかない入力は「対象の可能性あり」として確認を促します。

## 構成

```
scripts/check_api.py               # API 仕様のカナリア（GitHub Actions が毎日実行）
ios/
├── RecallMonitor.xcodeproj/       # Xcode プロジェクト（フォルダ同期方式）
└── RecallMonitor/
    ├── RecallMonitorApp.swift     # エントリポイント。バックグラウンド更新の登録
    ├── Models/                    # Recall / AffectedVehicle / Vehicle
    ├── Services/
    │   ├── RecallAPIClient.swift  # 国交省APIの呼び出しとレスポンス変換
    │   ├── RecallMatcher.swift    # 型式・車台番号の正規化と該当判定
    │   ├── NotificationManager.swift
    │   └── BackgroundRefreshManager.swift
    ├── ViewModels/                # RecallMonitorStore / VehicleStore
    ├── Views/                     # 検索・マイカー一覧・車両編集・新着一覧・詳細・設定
    └── Info.plist                 # BGTaskScheduler 設定ほか
```

配信サーバーは持ちません。以前は GitHub Actions で静的 JSON を生成して GitHub Pages で配る構成でしたが、API が型式で直接絞り込める以上は不要と判断し、すべて削除しました。GitHub Actions に残っているのは API 仕様のカナリアだけです。

## データソース

```
https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi
  ?blog_id=4
  &class=recalldatacar
  &model_name=<型式>                 # 部分一致。省略すると全件（新着順）
  &notification_date=<from> <to>     # YYYY/MM/DD を空白区切り
  &offset=<1始まり>&limit=<最大1000>
  &order_by=recall_data_car_mlit_notification_date
  &order_condition=STRD              # 降順
```

リコール情報検索画面（`recall-search.html`）が内部で使っている API です。型式・車台番号範囲・不具合の状況・改善措置まで構造化された JSON が返るため、HTML の解析は不要です。`robots.txt` は `#` のみで取得制限はありません（2026-09 時点）。

収録範囲は 1993年4月15日以降の届出で、全期間で 10,520 件ほどです。届出書の PDF は `https://renrakuda.mlit.go.jp/renrakuda/recallpdf/<届出番号>.pdf` で直接開けます。

### API の仕様変更を監視する

アプリは配信サーバーを持たず API を直接呼ぶため、**国交省側の仕様が変わると全端末が同時に壊れます**。しかもユーザーには「該当なし」としか見えないことがあり、誤答として現れます。

`.github/workflows/check-api.yml` が毎日 `scripts/check_api.py` を実行し、アプリが依存しているフィールドと挙動（エンドポイントの疎通、末尾カンマ込みの解析、`typeList` の分割構造、型式での部分一致）を検査します。失敗すると `api-breakage` ラベルの Issue を立てます。

手元でも実行できます。

```bash
python3 scripts/check_api.py
```

### 実装時に踏んだ落とし穴

このAPIは公開仕様ではないため、以下は実際に叩いて確かめた挙動です。コード側で対処済みですが、改修時は注意してください。

- **レスポンスの JSON に末尾カンマが混ざる**ことがあります（Movable Type のテンプレート由来）。素の `JSONDecoder` は失敗するので、`RecallAPIClient.stripTrailingCommas` を通しています。
- **`model_name` は小文字・全角のままだと 0 件**になります。`RecallMatcher.canonicalTypeCode` で全角→半角・大文字化し、日本語入力で混入しがちな長音符「ー」をハイフンに寄せてから渡します。
- **`model_name` は部分一致**です。`ZVW50` でも `DAA-ZVW50` の届出にヒットします。端末側の判定もこれに合わせてあります（完全一致で再フィルタすると、サーバーが返したものを取りこぼします）。
- **輸入車は車台番号ではなくシリアル番号で届け出**られます（例 `VF3LCYHZRLS037790`）。国産車の `ZVW50-6000001` と違って連番として比較できず、全期間の対象範囲 92,918 件のうち 20,704 件（22%）がこれに当たります。比較できない範囲は「対象外」と判定せず、型式一致のみで「対象の可能性あり」として扱います。
- **対象型式は `typeList` に 32 件までしか入らず、超過分が `typeList1`〜`typeList60` に分割**されます。実データ 4,000 件のうち 278 件（7%）が該当し、`typeList` だけを読むと 21,928 件の型式エントリが落ちます。対象車種の多い大規模リコールほど分割されるため、いちばん該当者が多い届出で「該当なし」と誤答します。車台番号範囲も `chassis_list1`〜`5` へ分割されうるので、あわせて集約します。
- **車台番号は区切りなしでも入力されます**（`ZVW506000100`）。型式部分にも数字が含まれるため「末尾の数字列」で切ると `ZVW` / `506000100` と誤ります。届出側が持つ範囲のプレフィックス（`ZVW50`）を起点に削って、残りを連番として扱います。
- 国交省側は **18時〜翌8時頃がデータ更新帯**で、その時間は繋がりにくくなります。

## 該当判定

| 入力 | 判定 | 表示 |
|---|---|---|
| 型式のみが一致 | `.possible` | 対象の可能性あり（車台番号で確認してください） |
| 型式＋車台番号が範囲内 | `.confirmed` | 対象です |
| 型式は一致・車台番号が範囲外 | `.none` | 表示しない |
| 型式は一致・車台番号が読み取れない | `.possible` | 対象の可能性あり |
| 型式が一致しない | `.none` | 表示しない |

車台番号が範囲内であっても、仕様（変速機の違い、ターボの有無など）により対象外の場合があります。最終的な確認は自動車メーカーまたは販売会社へ、という案内を詳細画面に出しています。

## セットアップ

Xcode 16 以降と iOS 17 以降が必要です。

```bash
open ios/RecallMonitor.xcodeproj
```

そのまま実行できます。プロジェクトはフォルダ同期方式（`PBXFileSystemSynchronizedRootGroup`）なので、`ios/RecallMonitor/` に Swift ファイルを足せば自動的にターゲットへ入ります。実機で試す場合は Signing & Capabilities でチームを選んでください。

コマンドラインからビルドする場合:

```bash
xcodebuild -project ios/RecallMonitor.xcodeproj -scheme RecallMonitor -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## 通知について

マイカーに登録した車両に対して、起動時と `BGAppRefreshTask`（OS 判断で1日1回程度）に問い合わせ、新しく該当したリコールをローカル通知します。登録していない場合、通知は行いません。

即時のリモート通知が必要なら APNs/FCM への移行が要りますが、そのためには誰がどの型式を登録しているかをサーバー側で預かることになります。個人開発の規模ではローカル通知で足りると判断しています。

## 免責

本アプリの情報は国土交通省の公開データに基づきますが、正確性を保証するものではありません。API は公開仕様として提供されているものではなく、予告なく変更・停止される可能性があります。リコールの該当可否は必ず自動車メーカーまたは販売会社にご確認ください。
