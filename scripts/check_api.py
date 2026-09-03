# -*- coding: utf-8 -*-
"""国土交通省 renrakuda API のカナリア。

アプリは配信サーバーを持たず API を直接呼ぶため、サイト仕様が変わると
全端末が同時に壊れる。しかも「壊れた」ことに気づく手段がユーザーからの
報告しかない。毎日ここで検査し、壊れていたら Issue を立てて気づけるようにする。

検査するのは ios/RecallMonitor/Services/RecallAPIClient.swift が依存している
ものだけに絞る。ここが通れば、少なくともアプリが読むフィールドは生きている。

    python3 scripts/check_api.py

失敗すると終了コード 1 を返す。
"""
import json
import sys
import urllib.parse
import urllib.request

API = "https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi"
UA = {"User-Agent": "Mozilla/5.0 (compatible; RecallMonitorCanary/1.0)"}

# 実在することが分かっている型式。これで引けなくなったら検索が壊れている。
KNOWN_MODEL = "DAA-ZVW50"

failures = []


def check(label, condition, detail=""):
    if condition:
        print(f"  ok  {label}")
    else:
        print(f"  NG  {label}" + (f" — {detail}" if detail else ""))
        failures.append(label if not detail else f"{label}（{detail}）")


def strip_trailing_commas(s):
    """RecallAPIClient.stripTrailingCommas と同じ処理。
    レスポンスに末尾カンマが混ざるため、これを外すと解析できない。"""
    out, i, n, in_str, esc = [], 0, len(s), False, False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            out.append(c)
        elif c == ",":
            j = i + 1
            while j < n and s[j] in " \t\r\n":
                j += 1
            if j < n and s[j] in "]}":
                i = j
                continue
            out.append(c)
        else:
            out.append(c)
        i += 1
    return "".join(out)


def fetch(model_name="", limit=50):
    params = {
        "blog_id": "4",
        "class": "recalldatacar",
        "notification_date": "0000/00/00 9999/12/31",
        "offset": "1",
        "limit": str(limit),
        "order_by": "recall_data_car_mlit_notification_date",
        "order_condition": "STRD",
    }
    if model_name:
        params["model_name"] = model_name
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as res:
        return res.read().decode("utf-8", errors="replace")


def main():
    print("1) エンドポイントの疎通")
    try:
        raw = fetch(limit=200)
    except Exception as e:
        check("API に到達できる", False, f"{type(e).__name__}: {e}")
        return report()

    # 誤ったパスは 404 ではなく 200 + 本文 0 バイトを返す。長さを見ること。
    check("応答が空でない", len(raw.strip()) > 0, f"{len(raw)} バイト")
    if not raw.strip():
        return report()

    print("2) レスポンスの解析")
    try:
        body = raw[raw.index("{"): raw.rindex("}") + 1]
        data = json.loads(strip_trailing_commas(body))
    except Exception as e:
        check("JSON として解析できる", False, f"{type(e).__name__}: {e}")
        return report()
    check("JSON として解析できる", True)

    records = data.get("data")
    check("data 配列がある", isinstance(records, list) and len(records) > 0)
    if not records:
        return report()

    print("3) 届出のフィールド")
    rec = records[0]
    for field in [
        "recall_data_car_mlit_notification_no",
        "recall_data_car_mlit_notification_date",
        "recall_data_car_mlit_defective_device",
        "recall_data_car_mlit_situation_explanatory_text",
        "recall_data_car_mlit_measures_explanatory_text",
        "recall_data_car_mlit_recall_campaign_flag",
        "recall_data_car_mlit_delete_flag",
        "typeList",
    ]:
        check(field, field in rec)

    print("4) 型式・車台番号の構造")
    a_type = next((t for r in records for t in (r.get("typeList") or [])), None)
    check("typeList に要素がある", a_type is not None)
    if a_type:
        for field in [
            "recall_type_data_car_mlit_car_name_code",
            "recall_type_data_car_mlit_model_name",
            "recall_type_data_car_mlit_common_name",
            "recall_type_data_car_mlit_chassis_list",
        ]:
            check(field, field in a_type)

    chassis = next(
        (c for r in records for t in (r.get("typeList") or [])
         for c in (t.get("recall_type_data_car_mlit_chassis_list") or [])), None)
    check("chassis_list に要素がある", chassis is not None)
    if chassis:
        # 「_to_to」は API 側の誤記だが、変わると車台番号の範囲が読めなくなる
        check("mst_chassis_car_mlit_chassis_no_from", "mst_chassis_car_mlit_chassis_no_from" in chassis)
        check("mst_chassis_car_mlit_chassis_to_to", "mst_chassis_car_mlit_chassis_to_to" in chassis)

    print("5) typeList の分割構造")
    # 型式は typeList に 32 件までしか入らず、超過分が typeList1〜60 に分かれる。
    # ここを読まないと大規模リコールで対象型式を取りこぼすため、構造の存続を確認する。
    check("typeList1 キーが存在する", "typeList1" in rec)
    split_records = [r for r in records if any(r.get(f"typeList{i}") for i in range(1, 61))]
    check("分割を持つ届出が実際にある", len(split_records) > 0,
          f"{len(records)} 件中 {len(split_records)} 件")

    print("6) 型式での絞り込み")
    try:
        raw2 = fetch(model_name=KNOWN_MODEL, limit=10)
        body2 = raw2[raw2.index("{"): raw2.rindex("}") + 1]
        hits = json.loads(strip_trailing_commas(body2)).get("data") or []
    except Exception as e:
        check(f"model_name={KNOWN_MODEL} で引ける", False, f"{type(e).__name__}: {e}")
        hits = []
    check(f"model_name={KNOWN_MODEL} で引ける", len(hits) > 0, f"{len(hits)} 件")

    # 排ガス記号なしでも引けること（アプリは部分一致を前提に判定している）
    try:
        raw3 = fetch(model_name="ZVW50", limit=10)
        body3 = raw3[raw3.index("{"): raw3.rindex("}") + 1]
        partial = json.loads(strip_trailing_commas(body3)).get("data") or []
    except Exception:
        partial = []
    check("model_name の部分一致が効く", len(partial) > 0, f"{len(partial)} 件")

    return report()


def report():
    print()
    if failures:
        print(f"失敗 {len(failures)} 件:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("すべて通過。API はアプリが期待する形を保っています。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
