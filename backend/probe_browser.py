# -*- coding: utf-8 -*-
"""実ブラウザ（Playwright/Chromium）から renrakuda の検索 API が使えるかを確認する診断用スクリプト。

urllib からは CGI が常に空(Content-Length: 0)を返すため、
「ブラウザ判定(TLS/HTTP指紋)による遮断」か「IP による遮断」かを切り分ける。
同じ IP・同じ URL で実ブラウザなら通るなら前者、通らないなら後者。
"""
import json
import sys

from playwright.sync_api import sync_playwright

SEARCH_RESULT = ("https://renrakuda.mlit.go.jp/renrakuda/ris-search-result-car.html"
                 "?selCarTp=1")
API_MARK = "mt-estraier.cgi"


def main():
    captured = []

    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--lang=ja-JP"])
        context = browser.new_context(locale="ja-JP", timezone_id="Asia/Tokyo")
        page = context.new_page()

        def on_response(res):
            if API_MARK in res.url:
                try:
                    body = res.text()
                except Exception as e:
                    body = f"(本文取得失敗: {e})"
                captured.append((res.status, res.url, body))

        page.on("response", on_response)
        page.on("console", lambda m: print(f"    [console:{m.type}] {m.text[:200]}"))

        print(f"--- ページを開く: {SEARCH_RESULT}")
        page.goto(SEARCH_RESULT, wait_until="networkidle", timeout=90000)
        page.wait_for_timeout(5000)

        count_text = ""
        try:
            count_text = page.inner_text("#ris-count", timeout=5000)
        except Exception:
            pass
        print(f"--- 画面上の件数表示 #ris-count = {count_text!r}")

        browser.close()

    print(f"\n--- 捕捉した API レスポンス: {len(captured)} 件")
    for status, url, body in captured:
        print(f"\n  status={status} len={len(body)}")
        print(f"  url={url}")
        if not body.strip():
            print("  → 本文が空。実ブラウザでも空 = IP 単位の遮断が濃厚。")
            continue
        print("  → 本文あり。ブラウザ判定による遮断だった。")
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            print(f"  head={body[:500]!r}")
            continue
        rows = data.get("data") if isinstance(data, dict) else None
        if isinstance(rows, list) and rows:
            print(f"  rows={len(rows)} / count={rows[0].get('count')}")
            print("  ★ 1件目の全キー:")
            for k, v in rows[0].items():
                print(f"    {k} = {str(v)[:200]!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
