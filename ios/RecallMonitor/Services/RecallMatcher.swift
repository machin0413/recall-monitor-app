//
//  RecallMatcher.swift
//  登録車両とリコール対象（型式・車台番号範囲）のマッチング。
//
//  API の model_name は部分一致なので、サーバー側の絞り込みは粗いフィルタでしかない。
//  該当かどうかの確定判定はここで行う。
//

import Foundation

/// 照合の確度。安全に関わる情報なので「範囲を判定できなかった」ケースを
/// 取りこぼさず、要確認として拾い上げる。
enum MatchConfidence {
    /// 型式が一致し、車台番号も対象範囲内
    case confirmed
    /// 型式は一致するが、車台番号の範囲判定ができなかった
    /// （届出に範囲が無い／書式が違う／車台番号が未入力 など）
    case needsCheck
}

struct RecallMatch: Identifiable {
    let recall: Recall
    let confidence: MatchConfidence

    var id: String { recall.notificationNo }
}

enum RecallMatcher {

    /// 型式コードの正規化（英数字以外を除去して大文字化）
    static func normalizeTypeCode(_ s: String) -> String {
        let alnum = s.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(alnum))
    }

    /// 車台番号を (プレフィックス, 連番文字列) に分割
    /// "ZVW50-6000001" -> ("ZVW50", "6000001")
    static func split(_ vin: String) -> (prefix: String, seq: String)? {
        let v = vin.uppercased().replacingOccurrences(of: " ", with: "")
        let parts = v.split(separator: "-", omittingEmptySubsequences: true)
        if parts.count == 2, let seq = parts.last, seq.allSatisfy({ $0.isNumber }) {
            return (String(parts[0]), String(seq))
        }
        if let r = v.range(of: #"\d{6,}$"#, options: .regularExpression) {
            return (String(v[v.startIndex..<r.lowerBound]), String(v[r]))
        }
        return nil
    }

    private static func seqValue(_ s: String) -> Int? {
        let trimmed = s.drop(while: { $0 == "0" })
        return Int(trimmed.isEmpty ? "0" : String(trimmed))
    }

    /// 届出側のプレフィックスを手がかりに、利用者の車台番号から連番部分を取り出す。
    ///
    /// `split(_:)` だけに頼ると、区切りが無く型式にも数字が含まれる場合
    /// （"ZVW506000001"）に "ZVW" + "506000001" と誤分割してしまう。
    private static func sequence(of vin: String, matchingPrefix prefix: String) -> String? {
        let normVin = normalizeTypeCode(vin)
        let normPrefix = normalizeTypeCode(prefix)
        guard !normVin.isEmpty, !normPrefix.isEmpty, normVin.hasPrefix(normPrefix) else { return nil }
        let seq = String(normVin.dropFirst(normPrefix.count))
        guard !seq.isEmpty, seq.allSatisfy(\.isNumber) else { return nil }
        return seq
    }

    /// 車台番号が 1 つの範囲に入るか。判定できない場合は nil
    /// （「対象外」と「判定不能」を呼び出し側で区別できるようにする）。
    static func rangeContains(_ vin: String, range: VinRange) -> Bool? {
        guard let (prefix, fromSeq) = split(range.from), !fromSeq.isEmpty,
              let (_, toSeq) = split(range.to), !toSeq.isEmpty,
              let s = sequence(of: vin, matchingPrefix: prefix),
              let v = seqValue(s), let lo = seqValue(fromSeq), let hi = seqValue(toSeq) else {
            return nil
        }
        return lo <= v && v <= hi
    }

    /// 型式の比較キー。車検証どおりの "DAA-ZVW50" と、排出ガス規制記号を省いた
    /// "ZVW50" のどちらで入力されても一致するよう、両方を候補に持つ。
    ///
    /// API の model_name は部分一致なので "ZVW50" でも届出は返ってくる。
    /// ここで完全一致しか見ないと、返ってきた届出を取りこぼして
    /// 「該当なし」と誤表示してしまう。
    static func typeCodeKeys(_ s: String) -> Set<String> {
        let full = normalizeTypeCode(s)
        guard !full.isEmpty else { return [] }
        var keys: Set<String> = [full]
        let separators = CharacterSet(charactersIn: "-－‐−―ー")
        if let range = s.rangeOfCharacter(from: separators) {
            let base = normalizeTypeCode(String(s[range.upperBound...]))
            if !base.isEmpty { keys.insert(base) }
        }
        return keys
    }

    private static func typeCodeMatches(_ a: String, _ b: String) -> Bool {
        let ka = typeCodeKeys(a), kb = typeCodeKeys(b)
        return !ka.isEmpty && !kb.isEmpty && !ka.isDisjoint(with: kb)
    }

    /// 型式と車台番号から該当リコールを返す。
    ///
    /// 型式が一致した届出は必ず拾う。車台番号が範囲内だと確認できたときだけ
    /// `.confirmed`、判定できなければ `.needsCheck`。
    /// すべての範囲が「範囲外」と確定した型式レコードだけを除外する。
    ///
    /// 車台番号が空のとき（登録前のかんたん検索など）はすべて `.needsCheck` になる。
    static func matches(typeCode: String, vin: String, in recalls: [Recall]) -> [RecallMatch] {
        recalls.compactMap { recall -> RecallMatch? in
            var bestConfidence: MatchConfidence?

            for affected in recall.affected where typeCodeMatches(affected.typeCode, typeCode) {
                if affected.vinRanges.isEmpty {
                    bestConfidence = .needsCheck
                    continue
                }
                var sawUndecidable = false
                var inSomeRange = false
                for range in affected.vinRanges {
                    switch rangeContains(vin, range: range) {
                    case .some(true):  inSomeRange = true
                    case .some(false): break            // この範囲は外。他の範囲を見る
                    case .none:        sawUndecidable = true
                    }
                    if inSomeRange { break }
                }
                if inSomeRange {
                    return RecallMatch(recall: recall, confidence: .confirmed)
                }
                if sawUndecidable {
                    bestConfidence = .needsCheck
                }
                // すべての範囲が「範囲外」と確定した型式レコードは該当しない
            }
            return bestConfidence.map { RecallMatch(recall: recall, confidence: $0) }
        }
    }

    /// 1台分の登録車両に対して該当リコールを返す。
    static func matches(for vehicle: Vehicle, in recalls: [Recall]) -> [RecallMatch] {
        matches(typeCode: vehicle.typeCode, vin: vehicle.vin, in: recalls)
    }
}
