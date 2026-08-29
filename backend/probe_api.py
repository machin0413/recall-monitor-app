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


def probe(label: str, url: str, method: str = "GET", data: bytes = None, referer: str = ""):
    headers = dict(UA)
    if referer:
        headers["Referer"] = referer
    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    print(f"\n--- {label}")
    print(f"    {method} {url}")
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            body = _decode(res.read(), res.headers.get("Content-Encoding", ""))
            ctype = res.headers.get("Content-Type", "")
            print(f"    status={res.status} len={len(body)} type={ctype} final={res.geturl()}")
            if body:
                head_text = re.sub(r"\s+", " ", body[:400])
                print("    head=" + repr(head_text))
            return body
    except urllib.error.HTTPError as e:
        print(f"    HTTPError {e.code}")
    except Exception as e:
        print(f"    EXC {type(e).__name__}: {e}")
    return ""


def main():
    """renrakuda の CGI が使えない前提で、代替データソースの到達性を確かめる。"""
    print("=" * 70)
    print("A) renrakuda CGI: GET 以外の方法")
    print("=" * 70)
    api = BASE + "mt/mt-estraier.cgi"
    q = urllib.parse.urlencode({
        "blog_id": "4", "class": "recalldatacar",
        "notification_date": "0000/00/00 9999/12/31",
        "offset": "1", "limit": "2",
        "order_by": "recall_data_car_mlit_notification_date",
        "order_condition": "STRD"})
    probe("POST 形式", api, method="POST", data=q.encode(), referer=BASE)
    probe("末尾スラッシュ付き PATH_INFO", api + "/?" + q, referer=BASE)

    print("\n" + "=" * 70)
    print("B) 代替データソースの到達性")
    print("=" * 70)
    candidates = [
        ("旧オープンデータ(carinf)", "https://carinf.mlit.go.jp/jidosha/carinf/opendata/"),
        ("carinf トップ", "https://carinf.mlit.go.jp/jidosha/carinf/"),
        ("MLIT リコール情報", "https://www.mlit.go.jp/jidosha/carinf/rcl/"),
        ("MLIT 自動車トップ", "https://www.mlit.go.jp/jidosha/"),
        ("e-Gov データカタログ検索", "https://www.data.go.jp/data/dataset?q=%E3%83%AA%E3%82%B3%E3%83%BC%E3%83%AB"),
    ]
    for label, url in candidates:
        body = probe(label, url)
        if body:
            files = re.findall(r'href=["\']([^"\']+\.(?:csv|zip|xlsx?|json|xml))["\']', body, re.I)
            if files:
                print(f"    ★ データファイルらしきリンク {len(files)} 件:")
                for f in dict.fromkeys(files):
                    print("      ", urllib.parse.urljoin(url, f))
    print("\n完了")


if __name__ == "__main__":
    sys.exit(main())
