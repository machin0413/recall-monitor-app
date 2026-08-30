# -*- coding: utf-8 -*-
"""照合ロジックのテスト。国交省 API の実レスポンスの値をそのまま使う。

実行: python3 backend/test_matching.py
"""
import sys

from matching import (CONFIRMED, NEEDS_CHECK, match_recall, match_recalls,
                      norm_type_code, range_contains, sequence_of, split_vin,
                      type_code_keys, type_code_matches)

# 実データ: 届出 1146490（2020/01/29 シートベルト・トヨタ プリウス）
# 1 つの型式に不連続な範囲が 2 つある点に注意。
SEATBELT = {
    "no": "1146490",
    "affected": [
        {"type_code": "DAA-ZVW50", "vin_ranges": [("ZVW50-6000001", "ZVW50-6118168"),
                                                  ("ZVW50-8000001", "ZVW50-8077900")]},
        {"type_code": "DAA-ZVW51", "vin_ranges": [("ZVW51-6000001", "ZVW51-6085929"),
                                                  ("ZVW51-8000001", "ZVW51-8055104")]},
        {"type_code": "DAA-ZVW55", "vin_ranges": [("ZVW55-8000001", "ZVW55-8057941")]},
    ],
}
# 実データ: 届出 1141852（2018/01/31 エアバッグ）。範囲がずっと狭い。
AIRBAG = {
    "no": "1141852",
    "affected": [
        {"type_code": "DAA-ZVW50", "vin_ranges": [("ZVW50-6000001", "ZVW50-6006621"),
                                                  ("ZVW50-8000001", "ZVW50-8004701")]},
    ],
}
# 範囲の記載が無い届出（実データにも存在しうるケース）
NO_RANGE = {
    "no": "9999999",
    "affected": [{"type_code": "DAA-ZVW50", "vin_ranges": []}],
}

ALL = [SEATBELT, AIRBAG, NO_RANGE]

failures = []


def check(actual, expected, label):
    ok = actual == expected
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"  actual={actual!r} expected={expected!r}"))
    if not ok:
        failures.append(label)


# --- 正規化・分割 ---
check(norm_type_code("daa-zvw50"), "DAAZVW50", "型式は大文字化して区切りを除去する")

# --- 型式の一致（排出ガス規制記号の有無を吸収する） ---
check(sorted(type_code_keys("DAA-ZVW50")), ["DAAZVW50", "ZVW50"], "規制記号ありは両方をキーに持つ")
check(sorted(type_code_keys("ZVW50")), ["ZVW50"], "規制記号なしはそのまま")
check(type_code_matches("DAA-ZVW50", "DAA-ZVW50"), True, "同じ表記なら一致")
check(type_code_matches("DAA-ZVW50", "ZVW50"), True, "規制記号を省いて入力しても一致する")
check(type_code_matches("ZVW50", "DAA-ZVW50"), True, "逆向きでも一致する")
check(type_code_matches("DAA-ZVW50", "daa zvw50"), True, "小文字・空白を吸収する")
check(type_code_matches("DAA-ZVW50", "ZVW51"), False, "別の型式とは一致しない")
check(type_code_matches("DAA-ZVW50", "W50"), False, "末尾の部分文字列では一致させない")
check(type_code_matches("DAA-ZVW50", ""), False, "空文字とは一致しない")
check(split_vin("ZVW50-6000001"), ("ZVW50", "6000001"), "区切りありの車台番号を分割")
check(sequence_of("ZVW506000001", "ZVW50"), "6000001", "区切りなしでもプレフィックス起点で連番を取り出す")
check(sequence_of("ZVW50-6000001", "ZVW50"), "6000001", "区切りありでも同じ結果になる")
check(sequence_of("ZVW51-6000001", "ZVW50"), None, "プレフィックスが違えば取り出せない")

# --- 単一範囲の判定 ---
check(range_contains("ZVW50-6001234", "ZVW50-6000001", "ZVW50-6118168"), True, "範囲内なら True")
check(range_contains("ZVW50-6999999", "ZVW50-6000001", "ZVW50-6118168"), False, "範囲外なら False")
check(range_contains("", "ZVW50-6000001", "ZVW50-6118168"), None, "車台番号未入力なら判定不能")
check(range_contains("ZVW50-6001234", "", ""), None, "範囲の記載が無ければ判定不能")

# --- 不連続な複数範囲（今回の実データで最も重要な挙動） ---
check(match_recall("DAA-ZVW50", "ZVW50-6001234", SEATBELT), CONFIRMED, "1つ目の範囲に入れば対象確定")
check(match_recall("DAA-ZVW50", "ZVW50-8050000", SEATBELT), CONFIRMED, "2つ目の範囲に入っても対象確定")
check(match_recall("DAA-ZVW50", "ZVW50-7000000", SEATBELT), None,
      "どの範囲にも入らなければ該当しない（範囲の隙間を対象にしない）")
check(match_recall("DAA-ZVW50", "ZVW50-6118168", SEATBELT), CONFIRMED, "範囲の上端は対象に含む")
check(match_recall("DAA-ZVW50", "ZVW50-6000001", SEATBELT), CONFIRMED, "範囲の下端は対象に含む")
check(match_recall("DAA-ZVW50", "ZVW50-6118169", SEATBELT), None, "上端の 1 つ外は対象外")

# --- 型式ごとに範囲が違う ---
check(match_recall("DAA-ZVW55", "ZVW55-8000500", SEATBELT), CONFIRMED, "別型式でも自分の範囲で判定する")
check(match_recall("DAA-ZVW55", "ZVW55-6000500", SEATBELT), None, "ZVW55 に 6 系の範囲は無いので対象外")

# --- 届出ごとに範囲の広さが違う ---
check(match_recall("DAA-ZVW50", "ZVW50-6100000", SEATBELT), CONFIRMED, "広い届出には該当する")
check(match_recall("DAA-ZVW50", "ZVW50-6100000", AIRBAG), None, "狭い届出には該当しない")

# --- 要確認になるケース ---
check(match_recall("DAA-ZVW50", "", SEATBELT), NEEDS_CHECK, "車台番号が空なら要確認")
check(match_recall("DAA-ZVW50", "ZVW50-6001234", NO_RANGE), NEEDS_CHECK, "範囲の記載が無ければ要確認")
check(match_recall("DAA-ZVW50", "でたらめな番号", SEATBELT), NEEDS_CHECK, "書式が違えば要確認（取りこぼさない）")
check(match_recall("CBA-A200A", "A200A-0000100", SEATBELT), None, "型式が違えば該当しない")
check(match_recall("ZVW50", "ZVW50-6001234", SEATBELT), CONFIRMED,
      "規制記号を省いた型式でも対象確定になる（API は部分一致で返すため取りこぼさない）")

# --- まとめて照合 ---
check([r["no"] for r, _ in match_recalls("DAA-ZVW50", "ZVW50-6001234", ALL)],
      ["1146490", "1141852", "9999999"], "範囲が狭い届出にも入る車台番号は 3 件すべて該当")
check([(r["no"], c) for r, c in match_recalls("DAA-ZVW50", "ZVW50-6100000", ALL)],
      [("1146490", CONFIRMED), ("9999999", NEEDS_CHECK)],
      "エアバッグの範囲外なら 2 件（うち 1 件は要確認）")
check([r["no"] for r, _ in match_recalls("DAA-ZVW50", "", ALL)],
      ["1146490", "1141852", "9999999"], "車台番号なしなら型式一致の全件を要確認で拾う")
check(all(c == NEEDS_CHECK for _, c in match_recalls("DAA-ZVW50", "", ALL)),
      True, "車台番号なしの結果はすべて要確認")

print()
if failures:
    print(f"❌ {len(failures)} 件失敗")
    sys.exit(1)
print("✅ 全テスト通過")
