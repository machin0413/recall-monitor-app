# -*- coding: utf-8 -*-
"""国土交通省 renrakuda API のカナリア（監視スクリプト）。

アプリは API を直接呼ぶため、サイト仕様が変わると全端末が同時に壊れる。
それをユーザーからの報告より先に検知するのがこのスクリプトの役割。
site/config.json に書かれた設定で実際に問い合わせ、
アプリが依存しているフィールドが揃っているかまで検査する。

失敗した場合は終了コード 1 を返し、ワークフローが Issue を立てる。

Usage:
    python3 check_api.py [--config ../site/config.json]
"""
import argparse
import gzip
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(BASE_DIR, "..", "site", "config.json")

# アプリが表示・照合に使っているフィールド。欠けたら壊れる。
REQUIRED_DATA_FIELDS = [
    "notification_no",
    "notification_date",
    "defective_device",
    "situation_explanatory_text",
    "measures_explanatory_text",
    "recall_campaign_flag",
    "id",
]
REQUIRED_TYPE_FIELDS = ["model_name", "car_name_code", "common_name"]
REQUIRED_CHASSIS_FIELDS = ["chassis_no_from", "chassis_to_to"]

# 実在する型式。ここで必ず 1 件以上返るはず（トヨタ プリウス 50 系）
CANARY_MODEL = "DAA-ZVW50"

UA = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
    "Accept": "application/json",
    "Accept-Language": "ja,en-US;q=0.9",
    "Accept-Encoding": "gzip, deflate",
}


def _decode(raw: bytes, encoding: str) -> str:
    if encoding == "gzip":
        try:
            raw = gzip.GzipFile(fileobj=io.BytesIO(raw)).read()
        except OSError:
            pass
    elif encoding == "deflate":
        try:
            raw = zlib.decompress(raw, -zlib.MAX_WBITS)
        except zlib.error:
            pass
    return raw.decode("utf-8", "replace")


def fetch(url: str, timeout: int = 60):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, _decode(res.read(), res.headers.get("Content-Encoding", ""))
    except urllib.error.HTTPError as e:
        return e.code, _decode(e.read() or b"", e.headers.get("Content-Encoding", ""))
    except Exception as e:
        return f"EXC:{type(e).__name__}:{e}", ""


def build_url(config: dict, model_name: str, limit: int = 5) -> str:
    names = config["param_names"]
    params = dict(config["fixed_params"])
    params[names["offset"]] = "1"
    params[names["limit"]] = str(limit)
    params[names["notification_date"]] = "0000/00/00 9999/12/31"
    params[names["model_name"]] = model_name
    return config["endpoint"] + "?" + urllib.parse.urlencode(params)


def parse_body(body: str):
    """アプリ側と同じ手順でパースする（前後の空白除去 + 末尾カンマ除去）。"""
    text = re.sub(r",\s*(\]\s*\}\s*)$", r"\1", body.strip())
    return json.loads(text)


def type_items(row: dict) -> list:
    items = []
    if isinstance(row.get("typeList"), list):
        items += row["typeList"]
    for i in range(1, 61):
        v = row.get(f"typeList{i}")
        if isinstance(v, list):
            items += v
    return items


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=DEFAULT_CONFIG)
    args = ap.parse_args(argv)

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)

    problems = []
    print(f"エンドポイント: {config['endpoint']}")

    url = build_url(config, CANARY_MODEL)
    print(f"問い合わせ: {url}")
    t0 = time.time()
    status, body = fetch(url)
    elapsed = time.time() - t0
    print(f"応答: status={status} {elapsed:.1f}s {len(body.encode('utf-8'))} bytes")

    if status != 200:
        problems.append(f"HTTP ステータスが 200 ではありません: {status}")
        return report(problems)

    if not body.strip():
        problems.append(
            "本文が空です。エンドポイントのパスが変わった可能性があります"
            "（/mt/mt-estraier.cgi はサイトルート直下。/renrakuda/ を挟むと空応答になります）")
        return report(problems)

    try:
        data = parse_body(body)
    except json.JSONDecodeError as e:
        problems.append(f"JSON として解釈できません: {e}")
        return report(problems)

    rows = data.get("data") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        problems.append("レスポンスに data 配列がありません")
        return report(problems)
    if not rows:
        problems.append(f"型式 {CANARY_MODEL} で 0 件でした。model_name の絞り込み仕様が変わった可能性があります")
        return report(problems)

    print(f"取得件数: {len(rows)}")

    dp = config["field_prefixes"]["data"]
    tp = config["field_prefixes"]["type"]
    cp = config["field_prefixes"]["chassis"]

    row = rows[0]
    for field in REQUIRED_DATA_FIELDS:
        if dp + field not in row:
            problems.append(f"届出レコードに {dp}{field} がありません")

    items = type_items(row)
    if not items:
        problems.append("typeList が空です。型式・車台番号の照合ができません")
    else:
        item = items[0]
        for field in REQUIRED_TYPE_FIELDS:
            if tp + field not in item:
                problems.append(f"型リストに {tp}{field} がありません")

        chassis = []
        for key in ["chassis_list"] + [f"chassis_list{i}" for i in range(1, 6)]:
            v = item.get(tp + key)
            if isinstance(v, list):
                chassis += v
        if not chassis:
            problems.append(f"型式 {CANARY_MODEL} の車台番号範囲が空です")
        else:
            for field in REQUIRED_CHASSIS_FIELDS:
                if cp + field not in chassis[0]:
                    problems.append(f"車台番号レコードに {cp}{field} がありません")
            sample = chassis[0]
            print(f"車台番号範囲の例: {sample.get(cp + 'chassis_no_from')} 〜 {sample.get(cp + 'chassis_to_to')}")

    # 型式の絞り込みが実際に効いているか（全件が返っていないか）
    all_url = build_url(config, "", limit=5)
    _, all_body = fetch(all_url)
    try:
        all_rows = parse_body(all_body).get("data") or []
        total = all_rows[0].get("count") if all_rows else None
        if total and str(total).isdigit() and len(rows) >= int(total):
            problems.append("型式で絞り込めていません（全件が返っています）")
        print(f"全件数の目安: {total}")
    except Exception:
        print("全件数の確認はスキップしました")

    return report(problems)


def report(problems: list) -> int:
    if not problems:
        print("\nOK: アプリが依存している仕様に変化はありません")
        return 0
    print("\n国交省 API の仕様が変わった可能性があります:", file=sys.stderr)
    for p in problems:
        print(f"  - {p}", file=sys.stderr)
    print("\nsite/config.json を更新すれば、アプリを更新せずに全端末を復旧できます。", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
