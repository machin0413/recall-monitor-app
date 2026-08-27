# -*- coding: utf-8 -*-
"""型式・車台番号の正規化ユーティリティ。

国土交通省リコール情報の「対象型式」「車台番号範囲」と、
ユーザーがアプリに入力する「型式」「車台番号」の比較を
確実に行うための共通ロジック。

このモジュールは backend と iOS 側 (RecallMatcher.swift) の
両方で同じ仕様に合わせて実装する。変更時は両方を同期すること。
"""
import re

def norm_type_code(s: str) -> str:
    """型式コードを正規化する (例: 'DAA-ZVW50' -> 'DAAZVW50')。
    - 大文字化
    - ハイフン・空白などの区切りを除去
    """
    if not s:
        return ""
    return re.sub(r"[\s\-–—/／・.。]", "", s.upper()).strip()

def split_vin(vin: str):
    """車台番号を (プレフィックス, 連番) に分割する。

    例: 'ZVW50-0001234' -> ('ZVW50', '0001234')
    例: 'ZVW5012345'    -> ('ZVW50', '12345')   (区切りなし)
    区切りが付いていれば第1候補、無ければ末尾N桁(6桁以上)を連番とみなす。

    Returns:
        (prefix: str, seq: str)
    """
    if not vin:
        return ("", "")
    v = vin.strip().replace(" ", "").upper()
    m = re.match(r"^([A-Z0-9]+?)[-－\-](\d+)$", v)
    if m:
        return m.group(1), m.group(2)
    # 区切りなし: 末尾の数字連続部を連番とみなす (型式VINは通常6〜8桁)
    m2 = re.match(r"^([A-Z0-9]+?)(\d{6,})$", v)
    if m2:
        return m2.group(1), m2.group(2)
    return (v, "")

def seq_value(seq: str) -> int:
    try:
        return int(seq.lstrip("0") or "0")
    except ValueError:
        return -1

def vin_in_range(vin: str, prefix: str, start_seq: str, end_seq: str) -> bool:
    """車台番号が対象範囲内か判定する。

    Args:
        vin: 検査する車台番号 ('ZVW50-0001234' など)
        prefix: 対象車両の車台番号プレフィックス
        start_seq: 対象範囲 開始連番
        end_seq:   対象範囲 終了連番

    Returns:
        範囲内なら True
    """
    p, s = split_vin(vin)
    if not s:
        return False
    # プレフィックス一致 (正規化して比較)
    if norm_type_code(p) != norm_type_code(prefix):
        return False
    v = seq_value(s)
    if v < 0:
        return False
    lo = seq_value(start_seq)
    hi = seq_value(end_seq)
    return lo <= v <= hi

def dedupe_recalls(recalls):
    """同一リコール(届出番号)の重複を除去する。"""
    seen = set()
    out = []
    for r in recalls:
        key = r.get("recall_id") or (r.get("maker") or "") + "|" + (r.get("published_at") or "") + "|" + (r.get("title") or "")
        if key in seen:
            continue
        seen.add(key)
        out.append(r)
    return out
