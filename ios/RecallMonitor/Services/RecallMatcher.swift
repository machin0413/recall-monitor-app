//
//  RecallMatcher.swift
//  登録車両とリコール対象（型式・車台番号範囲）のマッチング。
//  正規化仕様は backend/normalize.py と同一。
//

import Foundation

/// 照合の確度。安全に関わる情報なので「範囲を判定できなかった」ケースを
/// 取りこぼさず、要確認として拾い上げる。
enum MatchConfidence {
    /// 型式が一致し、車台番号も対象範囲内
    case confirmed
    /// 型式は一致するが、車台番号の範囲判定ができなかった
    /// （届出に範囲が無い／書式が違う／車台番号が未登録 など）
    case needsCheck
}

struct RecallMatch: Identifiable {
    let recall: Recall
    let confidence: MatchConfidence

    var id: String { recall.recallId }
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
    /// "ZVW50-0001234" -> ("ZVW50", "0001234")
    /// "ZVW500001234"  -> ("ZVW50", "0001234")
    static func split(_ vin: String) -> (prefix: String, seq: String)? {
        let v = vin.uppercased().replacingOccurrences(of: " ", with: "")
        let parts = v.split(separator: "-", omittingEmptySubsequences: true)
        if parts.count == 2, let seq = parts.last, seq.allSatisfy({ $0.isNumber }) {
            return (String(parts[0]), String(seq))
        }
        if let r = v.range(of: #"\d{6,}$"#, options: .regularExpression) {
            let seq = String(v[r])
            let prefix = String(v[v.startIndex..<r.lowerBound])
            return (prefix, seq)
        }
        return nil
    }

    private static func seqValue(_ s: String) -> Int? {
        let trimmed = s.drop(while: { $0 == "0" })
        return Int(trimmed.isEmpty ? "0" : String(trimmed))
    }

    /// 届出側のプレフィックスを手がかりに、車台番号の連番部分を取り出す。
    ///
    /// `split(_:)` だけに頼ると、区切りが無く型式にも数字が含まれる場合
    /// （"ZVW500001234"）に "ZVW" + "500001234" と誤分割してしまう。
    /// 対象プレフィックスが分かっているときは、それを削って残りを連番とみなす。
    private static func sequence(of vin: String, matchingPrefix prefix: String) -> String? {
        let normVin = normalizeTypeCode(vin)
        let normPrefix = normalizeTypeCode(prefix)
        guard !normVin.isEmpty, !normPrefix.isEmpty, normVin.hasPrefix(normPrefix) else {
            return nil
        }
        let seq = String(normVin.dropFirst(normPrefix.count))
        guard !seq.isEmpty, seq.allSatisfy(\.isNumber) else { return nil }
        return seq
    }

    /// 車台番号が対象範囲内か判定。範囲を評価できない場合は nil を返す
    /// （「対象外」と「判定不能」を呼び出し側で区別できるようにする）。
    static func vinInRange(_ vin: String, prefix: String, start: String, end: String) -> Bool? {
        guard !prefix.isEmpty, !start.isEmpty, !end.isEmpty,
              let s = sequence(of: vin, matchingPrefix: prefix),
              let v = seqValue(s), let lo = seqValue(start), let hi = seqValue(end) else {
            return nil
        }
        return lo <= v && v <= hi
    }

    private static func typeCodeMatches(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && !b.isEmpty && normalizeTypeCode(a) == normalizeTypeCode(b)
    }

    /// 型式と車台番号から該当リコールを返す。
    ///
    /// 型式が一致した届出は必ず拾う。車台番号の範囲まで判定できた場合のみ
    /// `.confirmed`、判定できなければ `.needsCheck` として返す。
    /// 範囲外と確定した対象車両レコードだけを除外する。
    ///
    /// 車台番号が空のときは（登録前のかんたん検索など）すべて `.needsCheck` になる。
    static func matches(typeCode: String, vin: String, in recalls: [Recall]) -> [RecallMatch] {
        recalls.compactMap { recall -> RecallMatch? in
            var bestConfidence: MatchConfidence?

            for affected in recall.affected {
                guard affected.typeCodes.contains(where: { typeCodeMatches($0, typeCode) }) else {
                    continue
                }
                switch vinInRange(vin,
                                  prefix: affected.vinPrefix,
                                  start: affected.vinStart,
                                  end: affected.vinEnd) {
                case .some(true):
                    return RecallMatch(recall: recall, confidence: .confirmed)
                case .some(false):
                    continue        // 範囲外と確定。この対象レコードは該当しない
                case .none:
                    bestConfidence = .needsCheck
                }
            }
            return bestConfidence.map { RecallMatch(recall: recall, confidence: $0) }
        }
    }

    /// 1台分の登録車両に対して該当リコールを返す。
    static func matches(for vehicle: Vehicle, in recalls: [Recall]) -> [RecallMatch] {
        matches(typeCode: vehicle.typeCode, vin: vehicle.vin, in: recalls)
    }
}
