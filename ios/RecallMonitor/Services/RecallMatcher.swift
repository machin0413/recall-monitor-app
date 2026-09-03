//
//  RecallMatcher.swift
//  登録車両とリコール対象（型式・車台番号範囲）のマッチング。
//  backend/normalize.py と同一仕様。
//

import Foundation

enum RecallMatcher {

    /// 型式コードの正規化（全角→半角・大文字化・ASCII英数字以外を除去）
    /// 型式・車台番号は定義上 ASCII 英数字のみ。日本語キーボードでは「-」が
    /// 長音符「ー」(U+30FC) になることがあり、これは CharacterSet.alphanumerics
    /// に含まれてしまうため、英数字を明示的に残す実装にしている。
    /// backend/normalize.py の norm_type_code() と同一仕様。
    static func normalizeTypeCode(_ s: String) -> String {
        let halfwidth = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        let alnum = halfwidth.uppercased().unicodeScalars.filter {
            (0x30...0x39).contains($0.value) || (0x41...0x5A).contains($0.value)
        }
        return String(String.UnicodeScalarView(alnum))
    }

    /// 車台番号を (プレフィックス, 連番文字列) に分割
    /// "ZVW50-0001234" -> ("ZVW50", "0001234")
    /// "ZVW500001234"  -> ("ZVW50", "0001234")
    static func split(_ vin: String) -> (prefix: String, seq: String)? {
        let halfwidth = vin.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? vin
        let v = halfwidth.uppercased().replacingOccurrences(of: " ", with: "")
        // 「-」のほか、日本語入力で混入しがちな長音符・ダッシュ類も区切りとして扱う
        let separators = CharacterSet(charactersIn: "-\u{30FC}\u{FF70}\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}")
        let parts = v.split(omittingEmptySubsequences: true) { ch in
            ch.unicodeScalars.count == 1 && separators.contains(ch.unicodeScalars.first!)
        }
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

    /// 届出側の型式に、入力された型式が含まれるか。
    ///
    /// API の model_name は部分一致で絞り込むため、端末側も同じ基準にしないと
    /// サーバが返したものを取りこぼす。実データの型式は 'DAA-ZVW50' のように
    /// 排ガス記号つきで登録されており、利用者が 'ZVW50' とだけ入力しても
    /// 引けるようにする必要がある。
    private static func typeCodeMatches(_ affectedCode: String, _ query: String) -> Bool {
        let q = normalizeTypeCode(query)
        guard !q.isEmpty else { return false }
        return normalizeTypeCode(affectedCode).contains(q)
    }

    /// API の model_name に渡せる形に整える。
    /// 全角→半角・大文字化し、日本語入力で混入する長音符やダッシュ類を "-" に寄せる。
    /// API は小文字や全角のままだと 0 件を返すため、送信前に必ず通すこと。
    /// （判定用の normalizeTypeCode と違い、区切りの "-" は残す）
    static func canonicalTypeCode(_ s: String) -> String {
        let halfwidth = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        var out = ""
        for ch in halfwidth.uppercased() {
            if ch.isWhitespace { continue }
            out.append(dashLike.contains(ch) ? "-" : ch)
        }
        return out
    }

    /// 「-」として扱う文字。日本語キーボードでは長音符が入りやすい。
    private static let dashLike: Set<Character> = [
        "-", "\u{30FC}", "\u{FF70}", "\u{FF0D}",
        "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}",
    ]

    /// 該当度。車台番号なしでも「対象の可能性あり」まで判定できるようにする。
    /// マイカー登録なしの検索が主動線であり、車台番号は手元に無いことが多いため。
    enum MatchLevel: Int, Comparable {
        case none = 0        // 対象外
        case possible = 1    // 型式は一致。車台番号で要確認
        case confirmed = 2   // 型式・車台番号ともに一致（対象）

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 型式（＋任意の車台番号）が、1つの対象範囲にどこまで該当するか。
    /// 車台番号が空、または読み取れない場合は .none に落とさず .possible に倒す。
    /// リコールは見逃しの実害が大きく、広めに拾って確認を促す方が安全なため。
    static func level(typeCode: String, vinInput: String, affected: AffectedVehicle) -> MatchLevel {
        guard affected.typeCodes.contains(where: { typeCodeMatches($0, typeCode) }) else {
            return .none
        }
        // 輸入車のシリアル番号など、届出側の範囲を数値比較できない場合は確定させない
        guard affected.hasComparableRange else { return .possible }
        let trimmed = vinInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let parsed = split(trimmed), !parsed.seq.isEmpty else {
            return .possible
        }
        return vin(inRange: trimmed,
                   prefix: affected.vinPrefix,
                   start: affected.vinStart,
                   end: affected.vinEnd) ? .confirmed : .none
    }

    /// 1件の届出に対する最も強い該当度（複数の対象範囲のうち最良のもの）
    static func level(typeCode: String, vinInput: String, in recall: Recall) -> MatchLevel {
        recall.affected
            .map { level(typeCode: typeCode, vinInput: vinInput, affected: $0) }
            .max() ?? .none
    }

    /// 登録車両が「1つの対象範囲」に該当しうるか。
    /// 検索と同じ基準を使うため、範囲が判定できない届出も型式一致で拾う。
    static func matches(vehicle: Vehicle, affected: AffectedVehicle) -> Bool {
        level(typeCode: vehicle.typeCode, vinInput: vehicle.vin, affected: affected) != .none
    }
}
