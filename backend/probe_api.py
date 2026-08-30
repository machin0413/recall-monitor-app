# -*- coding: utf-8 -*-
"""型式で直接絞り込めるか（アプリから直接叩く構成が成立するか）を確かめる診断スクリプト。

このリポジトリの実行環境からは renrakuda へ到達できないため、
GitHub Actions ランナー上で実行してログから判断する。
"""
import gzip
import io
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib

BASE = "https://renrakuda.mlit.go.jp/renrakuda/"
# ENDPOINT はサイトルート相対。/renrakuda/ を挟むと 200 で空応答になる。
API = "https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi"
UA = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
    "Accept": "application/json",
    "Accept-Language": "ja,en-US;q=0.9",
    "Accept-Encoding": "gzip, deflate",
}


def _decode(raw, encoding):
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


def get(url, referer="", timeout=180):
    headers = dict(UA)
    if referer:
        headers["Referer"] = referer
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, _decode(res.read(), res.headers.get("Content-Encoding", ""))
    except urllib.error.HTTPError as e:
        return e.code, _decode(e.read() or b"", e.headers.get("Content-Encoding", ""))
    except Exception as e:
        return "EXC:" + type(e).__name__ + ":" + str(e), ""


def query(label, extra, limit="100"):
    params = {
        "blog_id": "4",
        "class": "recalldatacar",
        "notification_date": "0000/00/00 9999/12/31",
        "offset": "1",
        "limit": limit,
        "order_by": "recall_data_car_mlit_notification_date",
        "order_condition": "STRD",
    }
    params.update(extra)
    url = API + "?" + urllib.parse.urlencode(params)
    t0 = time.time()
    st, body = get(url, referer=BASE + "ris-search-result-car.html")
    ms = int((time.time() - t0) * 1000)
    print("\n--- " + label)
    print("    " + url)
    print("    status=%s  %d ms  %d bytes" % (st, ms, len(body.encode("utf-8"))))
    if not body.strip():
        print("    本文が空")
        return None
    text = re.sub(r",\s*(\]\s*\}\s*)$", r"\1", body.strip())
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        print("    JSON解釈失敗: %s" % e)
        return None
    rows = data.get("data") or []
    print("    rows=%d  count=%s" % (len(rows), rows[0].get("count") if rows else "-"))
    for r in rows[:4]:
        types = []
        for k, v in r.items():
            if k.startswith("typeList") and isinstance(v, list):
                for t in v:
                    mn = t.get("recall_type_data_car_mlit_model_name")
                    if mn:
                        types.append(mn)
        print("      %s %s / 型式=%s" % (
            r.get("recall_data_car_mlit_notification_date"),
            (r.get("recall_data_car_mlit_defective_device") or "")[:24],
            ",".join(dict.fromkeys(types))[:80]))
    return rows


def main():
    print("=" * 70)
    print("A) robots.txt")
    print("=" * 70)
    st, body = get("https://renrakuda.mlit.go.jp/robots.txt")
    print("status=%s\n%s" % (st, body[:600] if body else "(空)"))

    print("\n" + "=" * 70)
    print("B) 型式で絞り込めるか")
    print("=" * 70)
    query("型式フル指定 model_name=DAA-ZVW50", {"model_name": "DAA-ZVW50"})
    query("型式のみ model_name=ZVW50", {"model_name": "ZVW50"})
    query("部分一致の確認 model_name=ZVW", {"model_name": "ZVW"})

    print("\n" + "=" * 70)
    print("C) 期間で絞ったときの応答サイズ（定期確認の想定）")
    print("=" * 70)
    query("直近のみ 2026/06/01〜", {"notification_date": "2026/06/01 9999/12/31"})
    query("型式 + 直近", {"model_name": "DAA-ZVW50",
                          "notification_date": "2020/01/01 9999/12/31"})
    print("\n完了")
    return 0


if __name__ == "__main__":
    sys.exit(main())
