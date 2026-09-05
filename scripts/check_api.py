# -*- coding: utf-8 -*-
"""国土交通省 renrakuda API のカナリア。

アプリは配信サーバーを持たず API を直接呼ぶため、サイト仕様が変わると
全端末が同時に壊れる。しかも「壊れた」ことに気づく手段がユーザーからの
報告しかない。毎日ここで検査し、壊れていたら Issue を立てて気づけるようにする。

検査はアプリと同じ config.json を使って行う。config.json を書き換えて壊した
場合もここで気づける（設定が壊れると全端末が同時に壊れるため、API 本体より
先に検査する）。

検査するのは ios/RecallMonitor/Services/RecallAPIClient.swift が依存している
ものだけに絞る。ここが通れば、少なくともアプリが読むフィールドは生きている。

    python3 scripts/check_api.py

失敗すると終了コード 1 を返す。
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (compatible; RecallMonitorCanary/1.0)"}

# 実在することが分かっている型式。これで引けなくなったら検索が壊れている。
KNOWN_MODEL = "DAA-ZVW50"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(ROOT, "config.json")
BUILTIN_PATH = os.path.join(ROOT, "ios", "RecallMonitor", "Services", "RemoteConfig.swift")

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


def load_config():
    """アプリが読むのと同じ config.json を使って検査する。
    設定を書き換えて壊した場合も、ここで気づけるようにするため。"""
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


def fetch(cfg, model_name="", limit=50):
    """config.json の指定どおりにリクエストを組む（アプリと同じ組み立て方）"""
    names = cfg["param_names"]
    params = dict(cfg["query"])
    params[names["offset"]] = "1"
    params[names["limit"]] = str(limit)
    if model_name:
        params[names["model_name"]] = model_name
    url = cfg["endpoint"] + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as res:
        return res.read().decode("utf-8", errors="replace")


def check_config(cfg):
    """config.json の形と、アプリ内蔵の既定値とのずれを見る。
    config.json が壊れると全端末が壊れるので、API より先に検査する。"""
    print("0) config.json")
    for key in ("endpoint", "pdf_base", "query", "param_names"):
        check(f"{key} がある", key in cfg)
    if "param_names" in cfg:
        for key in ("model_name", "offset", "limit"):
            check(f"param_names.{key} がある", key in cfg["param_names"])
    if "endpoint" in cfg:
        check("endpoint が https", str(cfg["endpoint"]).startswith("https://"))
    if "pdf_base" in cfg:
        check("pdf_base が https", str(cfg["pdf_base"]).startswith("https://"))

    # 内蔵の既定値とずれていると、config.json を取れない端末だけ挙動が変わる
    try:
        with open(BUILTIN_PATH, encoding="utf-8") as f:
            swift = f.read()
    except OSError as e:
        check("RemoteConfig.swift を読める", False, str(e))
        return
    builtin = swift.split("static let builtIn")[-1] if "static let builtIn" in swift else ""
    for key in ("endpoint", "pdf_base"):
        value = str(cfg.get(key, ""))
        check(f"内蔵の既定値が config.json の {key} と一致", value and value in builtin,
              "RemoteConfig.swift の builtIn を config.json に合わせてください")
    for name in (cfg.get("query") or {}):
        check(f"内蔵の既定値に query.{name} がある", f'"{name}"' in builtin)
    for label, value in (cfg.get("param_names") or {}).items():
        check(f"内蔵の既定値の param_names.{label} が一致", f'"{value}"' in builtin,
              f"config.json は {value}")


def main():
    try:
        cfg = load_config()
    except Exception as e:
        check("config.json を読める", False, f"{type(e).__name__}: {e}")
        return report()
    check_config(cfg)

    print("1) エンドポイントの疎通")
    try:
        raw = fetch(cfg, limit=200)
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

    def search_models(model_name):
        raw = fetch(cfg, model_name=model_name, limit=10)
        body = raw[raw.index("{"): raw.rindex("}") + 1]
        return json.loads(strip_trailing_commas(body)).get("data") or []

    def contains_model(record, needle):
        """届出の型式（分割分も含む）に needle が含まれるか"""
        lists = [record.get("typeList") or []]
        lists += [record.get(f"typeList{i}") or [] for i in range(1, 61)]
        return any(needle in (t.get("recall_type_data_car_mlit_model_name") or "")
                   for lst in lists for t in lst)

    try:
        hits = search_models(KNOWN_MODEL)
    except Exception as e:
        check(f"model_name={KNOWN_MODEL} で引ける", False, f"{type(e).__name__}: {e}")
        return report()
    check(f"model_name={KNOWN_MODEL} で引ける", len(hits) > 0, f"{len(hits)} 件")

    # 件数だけ見ても不十分。パラメータ名が変わると API は絞り込みを無視して
    # 全件返すため、「0 件でない」は素通りしてしまう。中身が本当に
    # 指定した型式かどうかまで見る。
    if hits:
        matched = sum(1 for r in hits if contains_model(r, KNOWN_MODEL))
        check("絞り込みが実際に効いている", matched == len(hits),
              f"{len(hits)} 件中 {matched} 件しか {KNOWN_MODEL} を含まない"
              "（パラメータ名が変わり、絞り込みが無視されている可能性）")

    # 排ガス記号なしでも引けること（アプリは部分一致を前提に判定している）
    try:
        partial = search_models("ZVW50")
    except Exception:
        partial = []
    check("model_name の部分一致が効く", len(partial) > 0, f"{len(partial)} 件")
    if partial:
        matched = sum(1 for r in partial if contains_model(r, "ZVW50"))
        check("部分一致でも中身が一致している", matched == len(partial),
              f"{len(partial)} 件中 {matched} 件")

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
