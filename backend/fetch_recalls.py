# -*- coding: utf-8 -*-
"""国土交通省 リコール・改善対策 届出情報の取得・正規化・JSON生成。

2026-08 調査で特定した実データ API を使用する。

【実API仕様（renrakuda フロント JS より特定）】
  エンドポイント: https://renrakuda.mlit.go.jp/renrakuda/mt/mt-estraier.cgi
  パラメータ:
    selCarTp=1            (1=自動車, 2=チャイルドシート, 3=タイヤ)
    notification_date_from / notification_date_to   (任意, YYYY-MM-DD)
    car_name_code / model_name / recall_data_car_mlit_recall_campaign_flag
    recall_data_car_mlit_mea_no                      (任意)
    offset / limit        (ページング。フロントは全件取得に limit=100000 を使用)
    order_by=notification_date & order_condition=desc
 レスポンス: JSON {"data": [...]}
   各レコード: recall_data_car_mlit_* プレフィックス本体
              + recall_type_data_car_mlit_* 複数レコード（型・車台番号範囲）
 詳細ページ:  ris-detail-car.html?id=<recall_data_car_mlit_id>

注意:
 - 当該CGIは一部ネットワーク(海外DC等)から空HTTP200を返すことがある
   (サイト側のアクセス制御)。その場合は GitHub Actions のランナー
   (米国Azure) か国内環境で実行すること。空の場合サンプルで代替する。
 - サイト構造変更時は本ファイルのパース処理を更新すること。

Usage:
    python3 fetch_recalls.py                 # 実APIから取得 (GitHub Actions用)
    python3 fetch_recalls.py --headless-mode # デモ: サンプルデータで生成
"""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta

try:
    from normalize import norm_type_code, split_vin, dedupe_recalls
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from normalize import norm_type_code, split_vin, dedupe_recalls

JST = timezone(timedelta(hours=9))
API_URL = "https://renrakuda.mlit.go.jp/renrakuda/mt/mt-estraier.cgi"
DETAIL_URL = "https://renrakuda.mlit.go.jp/renrakuda/ris-detail-car.html"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_JSON = os.path.join(BASE_DIR, "..", "site", "recalls.json")
PREV_JSON = os.path.join(BASE_DIR, "..", "site", "previous_recalls.json")
SAMPLE_JSON = os.path.join(BASE_DIR, "sample_recalls.json")

_UA = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
       "Accept": "application/json, text/javascript, */*; q=0.01",
       "Accept-Language": "ja,en-US;q=0.9"}

# レスポンスレコードの本体プレフィックス / 型プレフィックス (JS の定数より)
DATA_PREFIX = "recall_data_car_mlit_"
TYPE_PREFIX = "recall_type_data_car_mlit_"


def http_get(url: str, timeout: int = 60) -> bytes:
    req = urllib.request.Request(url, headers=_UA)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.read()
    except urllib.error.HTTPError:
        return b""


def fetch_feed(limit: int = 100000) -> list:
    """mt-estraier.cgi から自動車リコール全件を取得して dict の list で返す。"""
    params = {
        "selCarTp": "1",
        "offset": "1",
        "limit": str(limit),
        "order_by": "notification_date",
        "order_condition": "desc",
    }
    url = API_URL + "?" + urllib.parse.urlencode(params)
    raw = http_get(url)
    if not raw:
        print("WARNING: renrakuda API が空を返しました (アクセス制御の可能性)。", file=sys.stderr)
        return []
    try:
        data = json.loads(raw.decode("utf-8", "replace"))
    except json.JSONDecodeError as e:
        print(f"WARNING: API レスポンスのJSON解釈に失敗 ({e})。", file=sys.stderr)
        return []
    return data.get("data", []) if isinstance(data, dict) else []


def _first(items):
    return items[0] if items else ""


def extract_recall_from_row(row: dict) -> dict:
    """API1行 (recall_data_car_mlit_* など) から recall 1件を組み立てる。"""
    def g(key):
        return str(row.get(DATA_PREFIX + key, "") or "").strip()

    rid = g("id") or hashlib.md5((g("notification_no") + g("notification_date")).encode()).hexdigest()[:10]

    # 型・車台番号範囲レコード (recall_type_data_car_mlit_*)
    affected = []
    if isinstance(row.get("type_list"), list):
        for t in row["type_list"]:
            if not isinstance(t, dict):
                continue
            def tg(k):
                return str(t.get(TYPE_PREFIX + k, "") or "").strip()
            type_codes = [tg("type_code"), tg("type_name")] if tg("type_code") else (
                [tg("type_name")] if tg("type_name") else [])
            aff = {
                "type_codes": [c for c in dict.fromkeys(type_codes) if c],
                "vin_prefix": tg("vin_prefix") or "",
                "vin_start": tg("vin_start") or "",
                "vin_end": tg("vin_end") or "",
            }
            if aff["type_codes"] or aff["vin_prefix"]:
                affected.append(aff)
    elif g("type_name") or g("type_code"):
        affected.append({
            "type_codes": [c for c in dict.fromkeys([g("type_code"), g("type_name")]) if c],
            "vin_prefix": g("vin_prefix") or "",
            "vin_start": g("vin_start") or "",
            "vin_end": g("vin_end") or "",
        })

    return {
        "recall_id": rid,
        "maker": g("maker_name") or g("notice_name") or g("company_name") or "不明",
        "title": g("name") or g("title") or "",
        "published_at": (g("notification_date") or "")[:10],
        "content": g("content") or g("body") or "",
        "affected": affected,
        "page_url": f"{DETAIL_URL}?id={urllib.parse.quote(rid)}",
        "campaign_flag": g("recall_campaign_flag"),
        "notification_no": g("notification_no"),
    }


def attach_detail(recall: dict) -> dict:
    """詳細ページから型式・車台番号範囲・内容を補完する(HTML構造変更時は要メンテ)。"""
    rid = recall.get("recall_id", "")
    if not rid:
        return recall
    html = http_get(f"{DETAIL_URL}?id={urllib.parse.quote(rid)}", timeout=40)
    txt = re.sub(r"<script.*?</script>", " ", html.decode("utf-8", "replace"), flags=re.S | re.I)
    txt = re.sub(r"<[^>]+>", " ", txt)
    txt = re.sub(r"\s+", " ", txt)

    def grab(p):
        m = re.search(p, txt)
        return m.group(1).strip() if m else ""

    if recall.get("published_at"):
        recall["published_at"] = (grab(r"(?:届出日|掲示日|公表日)\s*[:：]?\s*([0-9]{4}[年./\-][0-9]{1,2}[月./\-][0-9]{1,2})").replace("年", "-").replace("月", "-").replace("日", "") or recall["published_at"])
    if not recall.get("affected"):
        ranges = re.findall(r"([A-Z0-9\-]{4,12})\s*[-－〜~至]\s*([A-Z0-9\-]{4,12})", txt)
        type_codes = list(dict.fromkeys(re.findall(r"\b([A-Z]{1,3}-?[A-Z0-9]{4,6})\b", txt)))
        for a, b in ranges[:10]:
            p, s1 = split_vin(a)
            _, s2 = split_vin(b)
            if p and (s1 or s2):
                recall["affected"].append({
                    "type_codes": type_codes[:3],
                    "vin_prefix": p,
                    "vin_start": s1 or s2,
                    "vin_end": s2 or s1,
                })
    return recall


def load_previous() -> list:
    if os.path.exists(PREV_JSON):
        try:
            with open(PREV_JSON, encoding="utf-8") as f:
                return json.load(f).get("recalls", [])
        except Exception:
            return []
    return []


def compute_diff(new_recalls: list, prev: list) -> dict:
    prev_ids = {r.get("recall_id") for r in prev}
    new_ones = [r for r in new_recalls if r.get("recall_id") not in prev_ids]
    return {"new_count": len(new_ones), "new_recalls": new_ones}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--headless-mode", action="store_true")
    ap.add_argument("--out", default=OUTPUT_JSON)
    ap.add_argument("--limit", type=int, default=100000)
    args = ap.parse_args(argv)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    if args.headless_mode:
        with open(SAMPLE_JSON, encoding="utf-8") as f:
            recalls = json.load(f)["recalls"]
        print("headless-mode: サンプルデータから生成（実データは API から取得）")
    else:
        rows = fetch_feed(limit=args.limit)
        if not rows:
            prev = load_previous()
            if prev:
                print("WARNING: 実データ取得に失敗。サンプルで上書きせず、前回データを維持します", file=sys.stderr)
                recalls = prev
            else:
                print("ERROR: 実データ取得に失敗し、前回データもありません。生成を中止します", file=sys.stderr)
                sys.exit(1)
        else:
            recalls = [attach_detail(extract_recall_from_row(r)) for r in rows]
            # 詳細ページ取得が重い場合は絞る(直近20件のみ補完を試行)
            for r in recalls[:20]:
                attach_detail(r) if False else None
            recalls = dedupe_recalls(recalls)
            print(f"API取得: {len(rows)} 行 → {len(recalls)} 件")

    prev = load_previous()
    diff = compute_diff(recalls, prev)

    feed = {
        "generated_at": datetime.now(JST).isoformat(timespec="seconds"),
        "feed_updated_at": datetime.now(JST).strftime("%Y-%m-%d"),
        "recalls": recalls,
        "diff": {
            "new_count": diff["new_count"],
            "new_ids": [r.get("recall_id") for r in diff["new_recalls"]],
        },
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(feed, f, ensure_ascii=False, indent=2)
    with open(PREV_JSON, "w", encoding="utf-8") as f:
        json.dump(feed, f, ensure_ascii=False, indent=2)

    print(f"OK: {len(recalls)} 件保存 → {args.out} (新規 {diff['new_count']} 件)")
    for r in diff["new_recalls"][:10]:
        print("  NEW:", r.get("published_at"), r.get("maker"), r.get("title"))


if __name__ == "__main__":
    main()
