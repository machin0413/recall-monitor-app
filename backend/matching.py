# -*- coding: utf-8 -*-
"""型式・車台番号の照合ロジックの参照実装。

iOS 側 (ios/RecallMonitor/Services/RecallMatcher.swift) と同一仕様。
アプリは国交省 API を直接呼ぶので本番でこのコードは動かないが、
仕様を 1 か所に書き出してテストで守るために置いている。
**RecallMatcher.swift を変更したら、こちらも合わせて更新すること。**

判定の考え方:
  - API の model_name は部分一致なので、型式の確定判定はここで行う。
  - 型式が一致した届出は必ず拾う（安全側）。
  - 車台番号が範囲内だと確認できたときだけ「対象確定」。
  - 範囲を評価できないときは「要確認」として残す。
  - すべての範囲が「範囲外」と確定した型式レコードだけを除外する。
"""
import re

CONFIRMED = "confirmed"
NEEDS_CHECK = "needs_check"


def norm_type_code(s: str) -> str:
    """型式コードを正規化する（英数字以外を除去して大文字化）。"""
    return re.sub(r"[^0-9A-Z]", "", (s or "").upper())


def split_vin(vin: str):
    """車台番号を (プレフィックス, 連番) に分割する。

    'ZVW50-6000001' -> ('ZVW50', '6000001')
    区切りが無い場合は末尾の 6 桁以上の数字を連番とみなす（曖昧なので補助的な扱い）。
    """
    v = (vin or "").upper().replace(" ", "")
    m = re.match(r"^([^-]+)-(\d+)$", v)
    if m:
        return m.group(1), m.group(2)
    m2 = re.search(r"(\d{6,})$", v)
    if m2:
        return v[:m2.start()], m2.group(1)
    return None


def seq_value(seq: str):
    t = seq.lstrip("0")
    if t == "":
        return 0
    return int(t) if t.isdigit() else None


def sequence_of(vin: str, prefix: str):
    """届出側のプレフィックスを削って連番を取り出す。

    split_vin だけに頼ると、区切りが無く型式にも数字が含まれる場合
    ('ZVW506000001') に 'ZVW' + '506000001' と誤分割してしまう。
    """
    nv, np_ = norm_type_code(vin), norm_type_code(prefix)
    if not nv or not np_ or not nv.startswith(np_):
        return None
    seq = nv[len(np_):]
    return seq if seq.isdigit() and seq else None


def range_contains(vin: str, range_from: str, range_to: str):
    """車台番号が 1 つの範囲に入るか。判定できない場合は None を返す。"""
    sf = split_vin(range_from)
    st = split_vin(range_to)
    if not sf or not st:
        return None
    prefix, from_seq = sf
    _, to_seq = st
    seq = sequence_of(vin, prefix)
    if not seq:
        return None
    v, lo, hi = seq_value(seq), seq_value(from_seq), seq_value(to_seq)
    if v is None or lo is None or hi is None:
        return None
    return lo <= v <= hi


def match_recall(type_code: str, vin: str, recall: dict):
    """1 件の届出に対する照合結果を返す。該当しなければ None。

    recall は {"affected": [{"type_code": str, "vin_ranges": [(from, to), ...]}, ...]} 形式。
    """
    best = None
    for affected in recall.get("affected", []):
        if norm_type_code(affected.get("type_code", "")) != norm_type_code(type_code):
            continue
        ranges = affected.get("vin_ranges") or []
        if not ranges:
            best = NEEDS_CHECK
            continue

        saw_undecidable = False
        in_some_range = False
        for r_from, r_to in ranges:
            result = range_contains(vin, r_from, r_to)
            if result is True:
                in_some_range = True
                break
            if result is None:
                saw_undecidable = True
        if in_some_range:
            return CONFIRMED
        if saw_undecidable:
            best = NEEDS_CHECK
        # すべての範囲が「範囲外」と確定した型式レコードは該当しない
    return best


def match_recalls(type_code: str, vin: str, recalls: list):
    """該当する届出を (recall, confidence) の list で返す。"""
    out = []
    for recall in recalls:
        confidence = match_recall(type_code, vin, recall)
        if confidence:
            out.append((recall, confidence))
    return out
