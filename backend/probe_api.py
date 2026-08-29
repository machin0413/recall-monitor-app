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


# ENDPOINT はサイトルート相対。/renrakuda/ を挟むと 200 で空応答になるので注意。
API = "https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi"


def fetch(params: dict, timeout: int = 180):
    url = API + "?" + urllib.parse.urlencode(params)
    st, _, body = get(url, referer=BASE + "ris-search-result-car.html", timeout=timeout)
    print(f"\nGET {url}\n  status={st} len={len(body)}")
    if not body:
        return None
    # MT テンプレート由来の前後の空白と、末尾の余分なカンマを取り除いてから解釈する
    text = re.sub(r",\s*(\]\s*\}\s*)$", r"\1", body.strip())
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        print(f"  JSON解釈失敗: {e}")
        print(f"  tail={text[-300:]!r}")
        return None


def main():
    """正しいエンドポイントでレスポンス構造を確定させる。"""
    base = {
        "blog_id": "4",
        "class": "recalldatacar",
        "notification_date": "0000/00/00 9999/12/31",
        "order_by": "recall_data_car_mlit_notification_date",
        "order_condition": "STRD",
    }

    data = fetch({**base, "offset": "1", "limit": "1"})
    if not data:
        print("取得失敗。")
        return 1
    rows = data.get("data") or []
    print(f"  rows={len(rows)}")
    r = rows[0]
    print("\n★ 届出レコードのキー（typeList 以外）:")
    for k, v in r.items():
        if k.startswith("typeList"):
            print(f"  {k} = <list len={len(v) if isinstance(v, list) else '?'}>")
        else:
            print(f"  {k} = {str(v)[:300]!r}")

    tl = []
    for k, v in r.items():
        if k.startswith("typeList") and isinstance(v, list):
            tl.extend(v)
    print(f"\n★ typeList 合計 {len(tl)} 件。先頭 1 件の中身:")
    if tl:
        for k, v in tl[0].items():
            if isinstance(v, list):
                print(f"  {k} = <list len={len(v)}> 先頭={v[0] if v else None}")
            else:
                print(f"  {k} = {str(v)[:300]!r}")

    print("\n--- 全件取得の所要と件数を確認 ---")
    full = fetch({**base, "offset": "1", "limit": "100000"})
    if full:
        frows = full.get("data") or []
        print(f"★ 全件 = {len(frows)} 件 / count = {frows[0].get('count') if frows else None}")
    print("\n完了")
    return 0


if __name__ == "__main__":
    sys.exit(main())
