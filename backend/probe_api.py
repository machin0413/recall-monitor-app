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

BASE = "https://renrakuda.mlit.go.jp/renrakuda/"
UA = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
    "Accept": "text/html,application/xhtml+xml,application/json,*/*;q=0.8",
    "Accept-Language": "ja,en-US;q=0.9,en;q=0.8",
    "Accept-Encoding": "gzip, deflate",
}


def get(url: str, referer: str = "", timeout: int = 45):
    """(status, final_url, body_text) を返す。例外は握り潰して status に文字列を入れる。"""
    headers = dict(UA)
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            raw = res.read()
            if res.headers.get("Content-Encoding") == "gzip":
                raw = gzip.GzipFile(fileobj=io.BytesIO(raw)).read()
            return res.status, res.geturl(), raw.decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, url, (e.read() or b"").decode("utf-8", "replace")
    except Exception as e:  # URLError / timeout / TLS など
        return f"EXC:{type(e).__name__}:{e}", url, ""


def show(label: str, url: str, referer: str = "", head: int = 400):
    st, final, body = get(url, referer)
    print(f"\n--- {label}")
    print(f"    url    : {url}")
    print(f"    status : {st}  len={len(body)}  final={final}")
    if body:
        print(f"    head   : {body[:head]!r}")
    return body


def main():
    print("=" * 70)
    print("STEP 1: トップ／検索ページの到達性")
    print("=" * 70)
    pages = [
        ("top", BASE),
        ("search-car", BASE + "ris-search-car.html"),
        ("detail-car", BASE + "ris-detail-car.html"),
    ]
    html_by_name = {}
    for name, url in pages:
        html_by_name[name] = show(name, url)

    print("\n" + "=" * 70)
    print("STEP 2: フロント JS を収集して API 呼び出し箇所を抽出")
    print("=" * 70)
    scripts = []
    for name, html in html_by_name.items():
        for m in re.findall(r'<script[^>]+src=["\']([^"\']+)["\']', html or "", re.I):
            scripts.append(urllib.parse.urljoin(BASE, m))
    scripts = list(dict.fromkeys(scripts))
    print(f"検出 script: {len(scripts)} 件")
    for s in scripts:
        print("   ", s)

    keywords = ("cgi", "estraier", "selCarTp", "recall_data_car", "notification_date",
                "ajax", "offset", "limit")
    for s in scripts:
        st, _, js = get(s, referer=BASE)
        if not js:
            print(f"\n[js] {s} -> status={st} (本文なし)")
            continue
        hits = [k for k in keywords if k in js]
        print(f"\n[js] {s} -> status={st} len={len(js)} hits={hits}")
        if not hits:
            continue
        # API 呼び出し周辺を抜き出す
        for m in re.finditer(r"[^\n]{0,160}(?:\.cgi|estraier|selCarTp)[^\n]{0,240}", js):
            line = re.sub(r"\s+", " ", m.group(0)).strip()
            print("      >", line[:400])

    print("\n" + "=" * 70)
    print("STEP 3: 想定 API エンドポイントを直接叩く")
    print("=" * 70)
    candidates = [
        ("mt-estraier 全件", BASE + "mt/mt-estraier.cgi?" + urllib.parse.urlencode({
            "selCarTp": "1", "offset": "1", "limit": "5",
            "order_by": "notification_date", "order_condition": "desc"})),
        ("mt-estraier 素", BASE + "mt/mt-estraier.cgi?selCarTp=1"),
        ("mt-search", BASE + "mt/mt-search.cgi?selCarTp=1&offset=1&limit=5"),
        ("mt-estraier ルート直下", BASE + "mt-estraier.cgi?selCarTp=1&offset=1&limit=5"),
    ]
    for label, url in candidates:
        body = show(label, url, referer=BASE + "ris-search-car.html", head=1500)
        if body.lstrip().startswith(("{", "[")):
            try:
                data = json.loads(body)
            except json.JSONDecodeError as e:
                print(f"    JSON解釈失敗: {e}")
                continue
            print(f"    JSON OK: type={type(data).__name__}")
            if isinstance(data, dict):
                print(f"    top-level keys: {list(data)[:20]}")
                rows = data.get("data")
                if isinstance(rows, list) and rows:
                    print(f"    data件数: {len(rows)}")
                    print("    1件目のキー:")
                    for k, v in list(rows[0].items())[:60]:
                        print(f"      {k} = {str(v)[:80]!r}")

    print("\n完了")


if __name__ == "__main__":
    sys.exit(main())
