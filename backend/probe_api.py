# -*- coding: utf-8 -*-
"""国交省 renrakuda の実 API 仕様を調査するための使い捨て診断スクリプト。

このリポジトリの実行環境（Claude セッション等）からは renrakuda へ到達できないため、
GitHub Actions ランナー上で実行してログから仕様を読み取る目的で用意している。

Usage:
    python3 probe_api.py
"""
import gzip
import io
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


def main():
    # --- 1) トップページのリンクから検索ページの実 URL を探す ---
    top = dump("top.html", BASE)
    links = sorted({urllib.parse.urljoin(BASE, h) for h in
                    re.findall(r'<a[^>]+href=["\']([^"\'#]+)["\']', top, re.I)
                    if h.endswith(".html")})
    print("トップページ内の .html リンク:")
    for l in links:
        print("   ", l)

    # 検索系ページの候補を実際に叩いて生存確認
    print("\n検索ページ候補の生存確認:")
    search_pages = [l for l in links if "search" in l or "ris-" in l]
    for l in search_pages:
        st, _, body = get(l, referer=BASE)
        print(f"    {st:>6}  len={len(body):>7}  {l}")

    # --- 2) API 契約が書かれている JS を全文ダンプ ---
    for js_url in [
        BASE + "common/assets/js/lib/utils.js",
        BASE + "common/assets/js/pages/ris-detail-car.js",
    ]:
        body = dump(js_url.rsplit("/", 1)[-1] + " 全文", js_url, referer=BASE)
        print(body)

    # --- 3) 検索ページ固有 JS を探して全文ダンプ ---
    for page in search_pages:
        st, _, html = get(page, referer=BASE)
        if not isinstance(st, int) or st != 200:
            continue
        page_js = [urllib.parse.urljoin(BASE, s)
                   for s in re.findall(r'<script[^>]+src=["\']([^"\']+)["\']', html, re.I)
                   if "/pages/" in s]
        for js_url in page_js:
            body = dump(f"{page} の固有JS: {js_url}", js_url, referer=page)
            print(body)

    print("\n完了")


if __name__ == "__main__":
    sys.exit(main())
