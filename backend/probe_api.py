# -*- coding: utf-8 -*-
"""国交省 renrakuda の実 API 仕様を調査するための使い捨て診断スクリプト。

このリポジトリの実行環境（Claude セッション等）からは renrakuda へ到達できないため、
GitHub Actions ランナー上で実行してログから仕様を読み取る目的で用意している。

Usage:
    python3 probe_api.py
"""
import gzip
import io
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zlib

BASE = "https://renrakuda.mlit.go.jp/renrakuda/"
UA = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
    "Accept": "text/html,application/xhtml+xml,application/json,*/*;q=0.8",
    "Accept-Language": "ja,en-US;q=0.9,en;q=0.8",
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


def get(url: str, referer: str = "", timeout: int = 45):
    """(status, final_url, body_text) を返す。例外は握り潰して status に文字列を入れる。"""
    headers = dict(UA)
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, res.geturl(), _decode(res.read(), res.headers.get("Content-Encoding", ""))
    except urllib.error.HTTPError as e:
        return e.code, url, _decode(e.read() or b"", e.headers.get("Content-Encoding", ""))
    except Exception as e:  # URLError / timeout / TLS など
        return f"EXC:{type(e).__name__}:{e}", url, ""


def dump(label: str, url: str, referer: str = ""):
    st, final, body = get(url, referer)
    print(f"\n{'=' * 70}\n### {label}\n    url={url}\n    status={st} len={len(body)} final={final}\n{'=' * 70}")
    return body


def try_api(label: str, params: dict, show_keys: bool = False):
    url = BASE + "mt/mt-estraier.cgi?" + urllib.parse.urlencode(params)
    st, _, body = get(url, referer=BASE + "ris-search-result-car.html", timeout=120)
    print(f"\n[{label}] status={st} len={len(body)}")
    print(f"    {url}")
    if not body:
        return None
    # フロント同様、末尾の余分なカンマを除去してから JSON 解釈する
    text = re.sub(r",\s*(\]\s*\}\s*)$", r"\1", body.strip())
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        print(f"    JSON解釈失敗: {e} / head={body[:400]!r}")
        return None
    rows = data.get("data") if isinstance(data, dict) else None
    print(f"    top-level keys={list(data)[:10]} rows={len(rows) if isinstance(rows, list) else 'N/A'}")
    if isinstance(rows, list) and rows and show_keys:
        print("    ★ 1件目 全キー:")
        for k, v in rows[0].items():
            print(f"      {k} = {str(v)[:200]!r}")
    return rows


def main():
    """フロント JS から確定した契約でリコール API を叩き、レスポンス構造を確認する。"""
    base = {
        "blog_id": "4",
        "class": "recalldatacar",
        "notification_date": "0000/00/00 9999/12/31",
        "order_by": "recall_data_car_mlit_notification_date",
        "order_condition": "STRD",
    }
    try_api("確定契約 limit=2", {**base, "offset": "1", "limit": "2"}, show_keys=True)

    rows = try_api("全件 limit=100000", {**base, "offset": "1", "limit": "100000"})
    if rows:
        print(f"\n★ 全件数 = {len(rows)} / count フィールド = {rows[0].get('count')}")
        # 型リストの構造を 1 件だけ詳しく見る
        for r in rows[:40]:
            tl = r.get("typeList") or []
            if tl:
                print("\n★ typeList[0] の中身:")
                for k, v in tl[0].items():
                    print(f"      {k} = {str(v)[:200]!r}")
                break
    print("\n完了")


if __name__ == "__main__":
    sys.exit(main())
