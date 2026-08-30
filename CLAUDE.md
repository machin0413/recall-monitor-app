# 開発メモ

国土交通省のリコール情報から、自分の車両に該当するリコールを通知する iOS アプリ。
アプリが国交省の API を**直接**呼ぶ（配信サーバーは持たない）。

## ビルド

```bash
brew install xcodegen     # 初回のみ
./scripts/build.sh        # xcodegen generate → シミュレータ向けビルド
```

`.xcodeproj` は `project.yml` からの生成物でコミットしていない。
**Swift ファイルを追加・削除したら `xcodegen generate` を実行し直すこと。**

```bash
cd backend && python3 test_matching.py   # 照合ロジックのテスト
```

## 踏んではいけない罠

### エンドポイントはサイトルート直下

```
正: https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi
誤: https://renrakuda.mlit.go.jp/renrakuda/mt/mt-estraier.cgi
```

誤ったパスは **404 ではなく HTTP 200 + 本文 0 バイト**を返す。エラーにならないので気づきにくい。
実際この誤りで、初回から数日間サンプルデータが配信され続けていた。
「データが取れない」ときは、まずステータスではなく**本文の長さ**を見ること。

### クエリの形

```
blog_id=4
class=recalldatacar
notification_date=0000/00/00 9999/12/31   ← from/to ではなくスペース区切りの単一パラメータ
order_by=recall_data_car_mlit_notification_date
order_condition=STRD                       ← desc ではない
model_name=DAA-ZVW50                       ← 型式。部分一致
offset=1 / limit=200
```

`selCarTp` は画面遷移用のパラメータで、API には渡さない。

### レスポンスの癖

- Movable Type のテンプレート出力なので、JSON の前に空白・改行が入る（`trim` が必要）
- 配列末尾に余分なカンマが付くことがある（本家 JS も同じ正規表現で除去している）
- 型リストは `typeList` と `typeList1`〜`typeList60` に分割される。全部まとめる必要がある
- **メーカー名は届出側になく、型リストの `recall_type_data_car_mlit_car_name_code`**（"トヨタ"）にしかない

### 照合ロジックは 2 言語に同じ仕様がある

- `ios/RecallMonitor/Services/RecallMatcher.swift`（本番）
- `backend/matching.py` + `test_matching.py`（参照実装とテスト。CI で実行）

**片方だけ直すとズレる。必ず両方を更新すること。**

押さえるべき仕様:

1. `model_name` は部分一致なので、**型式の確定判定はクライアント側**で行う
2. 型式は「規制記号あり／なし」の両方をキーに持って突き合わせる。
   `ZVW50` と入力されても `DAA-ZVW50` の届出を取りこぼさないため
   （完全一致にすると「該当なし」の誤表示になる。過去に実際に起きた）
3. 1 つの型式に**不連続な複数の車台番号範囲**が入る
   （例: `ZVW50-6000001〜6118168` と `ZVW50-8000001〜8077900`）。
   範囲の隙間（`ZVW50-7000000`）を対象にしないよう、範囲ごとに判定する
4. 車台番号は区切りの有無どちらも受ける。区切りなし（`ZVW506000001`）は
   型式にも数字があるため単純分割では誤る。**届出側のプレフィックスを削って**連番を取る
5. 判定できないものは「対象外」にせず**「要確認」として残す**。
   安全に関わる情報なので、取りこぼしより過検出を選ぶ

## 仕様変更に備えた作り

エンドポイントとパラメータ名は `site/config.json` から取得し、失敗時は
`RemoteConfig.builtIn` にフォールバックする。国交省側の仕様が変わっても
**config.json を直せば App Store 更新なしで全端末が復旧する**。

`backend/check_api.py`（カナリア）が毎日 API を検査し、アプリが依存する
フィールドが欠けたら `api-breakage` ラベルの Issue を立てる。

## この環境で確認できていないこと

Linux 環境で開発したため、**Swift のコンパイルは一度も通していない**。
`project.yml` / `Info.plist` / `scripts/build.sh` も未検証。
最初のビルドでは設定の調整が要る可能性が高い。
