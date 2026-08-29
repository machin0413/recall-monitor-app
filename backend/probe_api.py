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


API = BASE + "mt/mt-estraier.cgi"
SEARCH_PAGE = BASE + "ris-search-result-car.html"
PARAMS = {
    "blog_id": "4",
    "class": "recalldatacar",
    "notification_date": "0000/00/00 9999/12/31",
    "offset": "1",
    "limit": "2",
    "order_by": "recall_data_car_mlit_notification_date",
    "order_condition": "STRD",
}


def attempt(label: str, headers: dict, opener=None, params: dict = None):
    """ヘッダ条件を変えて API を叩き、レスポンスヘッダまで含めて出力する。"""
    url = API + "?" + urllib.parse.urlencode(params or PARAMS)
    req = urllib.request.Request(url, headers=headers)
    op = opener or urllib.request.build_opener()
    print(f"\n--- {label}")
    try:
        with op.open(req, timeout=60) as res:
            raw = res.read()
            print(f"    status={res.status} bytes={len(raw)}")
            for k, v in res.headers.items():
                print(f"      {k}: {v}")
            body = _decode(raw, res.headers.get("Content-Encoding", ""))
            print(f"    body[:300]={body[:300]!r}")
            return body
    except urllib.error.HTTPError as e:
        raw = e.read() or b""
        print(f"    HTTPError status={e.code} bytes={len(raw)}")
        for k, v in e.headers.items():
            print(f"      {k}: {v}")
        print(f"    body[:300]={_decode(raw, e.headers.get('Content-Encoding', ''))[:300]!r}")
    except Exception as e:
        print(f"    EXC {type(e).__name__}: {e}")
    return ""


def main():
    """CGI が空を返す原因（ヘッダ/Cookie/エンコーディング）を切り分ける。"""
    browser = {
        "User-Agent": UA["User-Agent"],
        "Accept": "application/json",
        "Accept-Language": "ja,en-US;q=0.9",
        "Referer": SEARCH_PAGE,
        "Origin": "https://renrakuda.mlit.go.jp",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    }

    attempt("1) Accept:application/json のみ", {"Accept": "application/json"})
    attempt("2) ブラウザ相当ヘッダ(gzipなし)", browser)
    attempt("3) ブラウザ相当 + gzip", {**browser, "Accept-Encoding": "gzip, deflate"})
    attempt("4) X-Requested-With 付き", {**browser, "X-Requested-With": "XMLHttpRequest"})
    attempt("5) User-Agent なし", {k: v for k, v in browser.items() if k != "User-Agent"})

    # 6) セッション Cookie を取得してから叩く
    import http.cookiejar
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    for page in (BASE, BASE + "recall-search.html", SEARCH_PAGE):
        try:
            opener.open(urllib.request.Request(page, headers={"User-Agent": UA["User-Agent"]}), timeout=45).read()
        except Exception as e:
            print(f"    (先行アクセス失敗 {page}: {e})")
    print(f"\n取得できた Cookie: {[c.name for c in jar]}")
    attempt("6) Cookie 付き", browser, opener=opener)

    # 7) 極小パラメータ（class と blog_id だけ）
    attempt("7) 最小パラメータ", browser, params={"blog_id": "4", "class": "recalldatacar", "limit": "1", "offset": "1"})
    print("\n完了")


if __name__ == "__main__":
    sys.exit(main())
