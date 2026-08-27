//
//  RecallMatcher.swift
//  登録車両とリコール対象（型式・車台番号範囲）のマッチング。
//  backend/normalize.py と同一仕様。
//

import Foundation

enum RecallMatcher {

    /// 型式コードの正規化（大文字化・区切り除去）
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

    /// 車台番号が対象範囲内か判定
    static func vin(inRange vin: String, prefix: String, start: String, end: String) -> Bool {
        guard let (p, s) = split(vin), !s.isEmpty,
              let v = seqValue(s), let lo = seqValue(start), let hi = seqValue(end) else {
            return false
        }
        guard normalizeTypeCode(p) == normalizeTypeCode(prefix) else { return false }
        return lo <= v && v <= hi
    }

    private static func typeCodeMatches(_ a: String, _ b: String) -> Bool {
        normalizeTypeCode(a) == normalizeTypeCode(b)
    }

    /// 1台分の車両に対して該当リコールを返す
    static func recalls(matching vehicle: Vehicle, in recalls: [Recall]) -> [Recall] {
        recalls.filter { recall in
            recall.affected.contains { affected in
                let typeHit = affected.typeCodes.contains { typeCodeMatches($0, vehicle.typeCode) }
                let vinHit = vin(inRange: vehicle.vin,
                                 prefix: affected.vinPrefix,
                                 start: affected.vinStart,
                                 end: affected.vinEnd)
                return typeHit && vinHit
            }
        }
    }
}
