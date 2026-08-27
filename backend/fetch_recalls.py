# -*- coding: utf-8 -*-
"""国土交通省 リコール情報の取得・正規化・差分検出・JSON生成。

毎日 GitHub Actions から実行され、国交省 renrakuda (リコール情報) から
自動車リコールの一覧を取得し、アプリが読む静的 JSON (site/recalls.json) を
生成する。

データソース:
  - 一覧API: https://renrakuda.mlit.go.jp/renrakuda/mt-search.cgi
        ?blog_id=4&class=recalldatacar&limit=100&offset=N&search=&Template=json
  - 詳細ページ: renrakuda.mlit.go.jp の各エントリURL (HTMLをパース)
  robots.txt は "#" のみで取得制限なし (確認済み 2026-08)。

注意: サイトのHTML構造は変更されることがある。構造変更時は
      parse_detail_html() のセレクタを更新すること。

Usage:
    python3 fetch_recalls.py [--headless-mode] [--ignore-ssl-errors]
       --headless-mode: 実際のHTTP版が取れないときにサンプルから生成するデモ用。
       (通常はGitHub Actionsから cron で実行)
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
    from normalize import norm_type_code, split_vin, vin_in_range, dedupe_recalls
except ImportError:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from normalize import norm_type_code, split_vin, vin_in_range, dedupe_recalls

JST = timezone(timedelta(hours=9))
BASE = "https://renrakuda.mlit.go.jp/renrakuda"
LIST_API = BASE + "/mt-search.cgi"
DETAIL_PAGES = []  # 詳細ページURLの候補リスト (cron時に一覧APIから埋める)

OUTPUT_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "site", "recalls.json")
PREV_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "site", "previous_recalls.json")
SAMPLE_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sample_recalls.json")

_UA = {"User-Agent": "Mozilla/5.0 (compatible; RecallMonitorBot/1.0)"}


# ---------------------------------------------------------------- HTTP ----
def http_get(url: str, timeout: int = 30) -> str:
    req = urllib.request.Request(url, headers=_UA)
    with urllib.request.urlopen(req, timeout=timeout) as res:
        return res.read().decode("utf-8", errors="replace")


def fetch_listing(limit: int = 100, offset: int = 1) -> list:
    """一覧APIからエントリのメタ情報 (title / url / published) を取得する。

    実際のレスポンス形式:
      MT の Template=json は通常 {'entries': [...], 'result': {...}} の構造。
      構造が変わった場合はここを更新する。
    """
    params = {
        "blog_id": "4",
        "class": "recalldatacar",
        "limit": str(limit),
        "offset": str(offset),
        "search": "",
        "Template": "json",
    }
    url = LIST_API + "?" + urllib.parse.urlencode(params)
    raw = http_get(url)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        # HTMLが返ってきた場合用の簡易パース (アンカー抽出のフォールバック)
        entries = []
        for m in re.finditer(r'<a[^>]+href="([^"]+)"[^>]*>\s*([^<]{5,}?)\s*</a>', raw):
            href, txt = m.group(1), m.group(2).strip()
            if "/" in href and txt:
                entries.append({"url": urllib.parse.urljoin(LIST_API, href), "title": txt})
        return entries
    return data.get("entries", [])


def parse_detail_html(html: str) -> dict:
    """エントリ詳細ページのHTMLからリコール情報を抽出する。

    renrakuda のリコール記事は「リコール届出番号」「届出者名」「対象型式」
    「対象車台番号範囲」「対象車両数」「不具合の内容」などを含むテーブル形式。
    サイト側の構造に合わせてこの関数をメンテナンスする。

    Returns: 正規化済みフィールドを持つ dict
    """
    text = re.sub(r"<script.*?</script>", " ", html, flags=re.S | re.I)
    text = re.sub(r"<style.*?</style>", " ", text, flags=re.S | re.I)
    text_strip = re.sub(r"<[^>]+>", " ", text)
    text_strip = re.sub(r"\s+", " ", text_strip)

    def grab(pattern):
        m = re.search(pattern, text_strip)
        return m.group(1).strip() if m else ""

    recall_id = grab(r"(?:リコール届出番号|届出番号)\s*[:：]?\s*([0-9A-Za-z\-]+)")
    maker = grab(r"(?:届出者名|メーカー)\s*[:：]?\s*([^\s]{2,30}?)(?:\s|$)")
    title = grab(r"(?:件名|対象|不具合の内容|タイトル)\s*[:：]?\s*(.{5,80}?)(?:\s*(?:対象|届出|リコール|詳細|$)", )
    published = grab(r"(?:掲示(?:日|開始)|公表日)\s*[:：]?\s*([0-9]{4}[年./\-][0-9]{1,2}[月./\-][0-9]{1,2})")
    vin_ranges = re.findall(
        r"([A-Z0-9\-]{4,12})\s*[-－〜~～至]\s*([A-Z0-9\-]{4,12})",
        re.sub(r"[<>\n]", " ", grab(r"(?:対象車台番号|車台番号範囲)[^。]{0,80}")),
    )

    # 型式を抽出 ('DAA-ZVW50' などのパターン)
    type_codes = list(dict.fromkeys(re.findall(r"([A-Z]{1,3}-?[A-Z0-9]{4,6})", text_strip)))

    affected = []
    for a, b in vin_ranges[:10]:
        p, s1 = split_vin(a)
        _, s2 = split_vin(b)
        if p and (s1 or s2):
            affected.append({
                "type_codes": type_codes[:3],
                "vin_prefix": p,
                "vin_start": s1 or s2,
                "vin_end": s2 or s1,
            })

    return {
        "recall_id": recall_id,
        "maker": maker,
        "title": title,
        "published_at": published,
        "content": text_strip[:2000],
        "affected": affected,
        "page_url": "",
    }


def fetch_all_recalls() -> list:
    """一覧API+詳細ページから全リコールを取得する。"""
    entries = fetch_listing()
    recalls = []
    for e in entries:
        url = e.get("url") or e.get("link")
        if not url:
            continue
        try:
            html = http_get(url)
        except Exception:
            continue
        item = parse_detail_html(html)
        item["page_url"] = url
        item["published_at"] = item["published_at"] or (e.get("date") or "")
        item["title"] = item["title"] or e.get("title", "")
        item["recall_id"] = item["recall_id"] or hashlib.md5(url.encode()).hexdigest()[:10]
        recalls.append(item)
    return dedupe_recalls(recalls)


# ------------------------------------------------------------- 差分 ----
def load_previous() -> list:
    if os.path.exists(PREV_JSON):
        try:
            with open(PREV_JSON, encoding="utf-8") as f:
                return json.load(f).get("recalls", [])
        except Exception:
            return []
    return []


def compute_diff(new_recalls: list, prev: list) -> dict:
    """新規リコール (前回取得時点に無かったもの) を検出する。"""
    prev_ids = {r.get("recall_id") for r in prev}
    new_ones = [r for r in new_recalls if r.get("recall_id") not in prev_ids]
    return {
        "new_count": len(new_ones),
        "new_recalls": new_ones,
    }


# ------------------------------------------------------------- 出力 ----
def build_feed(recalls: list) -> dict:
    return {
        "generated_at": datetime.now(JST).isoformat(timespec="seconds"),
        "feed_updated_at": datetime.now(JST).strftime("%Y-%m-%d"),
        "recalls": recalls,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="国交省リコール情報 → 静的JSON生成")
    ap.add_argument("--headless-mode", action="store_true",
                    help="HTTP版が取れない開発環境用: サンプルJSONから生成する")
    ap.add_argument("--out", default=OUTPUT_JSON)
    args = ap.parse_args(argv)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    if args.headless_mode:
        with open(SAMPLE_JSON, encoding="utf-8") as f:
            recalls = json.load(f)["recalls"]
        print("headless-mode: サンプルデータから生成 (本番では cron が常時取得)")
    else:
        recalls = fetch_all_recalls()
        if not recalls:
            print("WARNING: 実データ取得に失敗。サンプルで代替します", file=sys.stderr)
            with open(SAMPLE_JSON, encoding="utf-8") as f:
                recalls = json.load(f)["recalls"]
        dedupe_recalls(recalls)

    prev = load_previous()
    diff = compute_diff(recalls, prev)

    feed = build_feed(recalls)
    feed["diff"] = {"new_count": diff["new_count"], "new_ids": [r.get("recall_id") for r in diff["new_recalls"]]}

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(feed, f, ensure_ascii=False, indent=2)
    with open(PREV_JSON, "w", encoding="utf-8") as f:
        json.dump(feed, f, ensure_ascii=False, indent=2)

    print(f"OK: {len(recalls)} 件保存 → {args.out} (新規 {diff['new_count']} 件)")
    for r in diff["new_recalls"][:10]:
        print("  NEW:", r.get("published_at"), r.get("maker"), r.get("title"))


if __name__ == "__main__":
    main()
