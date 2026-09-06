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

    /// 型式から照合用のキー集合を作る。
    ///
    /// 排ガス規制記号（ハイフンより前の 1〜3 文字。DAA, BC, 7CF など）は、
    /// **届出によって有ったり無かったりする**。実データでは同じ車体が
    /// 'BC-ZRT10A' と 'ZRT10A' の両方の表記で登録されており、記号つきで
    /// 入力すると記号なしの届出を取りこぼす。実際、車検証どおり 'BC-ZRT10A' と
    /// 入力すると 1999 年の届出（'ZRT10A' で登録）が見えなくなっていた。
    /// 実データのユニーク型式の 14% は記号を持たない。
    ///
    /// そこで記号を落とした本体も必ずキーに含め、照合はキー集合の積で行う。
    ///   'BC-ZRT10A' -> {BCZRT10A, ZRT10A}
    ///   'ZRT10A'    -> {ZRT10A}          → 積が空でないので一致
    static func typeCodeKeys(_ s: String) -> Set<String> {
        let canonical = canonicalTypeCode(s)
        var keys = Set<String>()
        let full = normalizeTypeCode(canonical)
        if !full.isEmpty { keys.insert(full) }
        if let hyphen = canonical.firstIndex(of: "-") {
            let body = normalizeTypeCode(String(canonical[canonical.index(after: hyphen)...]))
            if !body.isEmpty { keys.insert(body) }
        }
        return keys
    }

    /// 届出側の型式と入力が同じ車を指しているか。
    ///
    /// 部分一致ではなくキー集合の積で判定する。部分一致だと 'GG' が
    /// 'XXX-GGYY' にも当たってしまい、無関係な車を「対象の可能性あり」と
    /// 表示してしまう。キー方式なら記号の有無だけを吸収して他は取り違えない。
    static func typeCodeMatches(_ affectedCode: String, _ query: String) -> Bool {
        let queryKeys = typeCodeKeys(query)
        guard !queryKeys.isEmpty else { return false }
        return !typeCodeKeys(affectedCode).isDisjoint(with: queryKeys)
    }

    /// API の model_name に渡す文字列。
    ///
    /// 排ガス記号を落とした本体を投げる。API の絞り込みは部分一致なので、
    /// 'BC-ZRT10A' をそのまま投げると 'ZRT10A' で登録された届出が返ってこない。
    /// 本体で広く網を張り、絞り込みは端末側の typeCodeMatches で行う。
    static func searchQuery(for typeCode: String) -> String {
        let canonical = canonicalTypeCode(typeCode)
        if let hyphen = canonical.firstIndex(of: "-") {
            let body = String(canonical[canonical.index(after: hyphen)...])
            if !body.isEmpty { return body }
        }
        return canonical
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

    /// 届出側のプレフィックスを手がかりに、車台番号から連番部分を取り出す。
    ///
    /// 'ZVW50-6000100' のように区切りがあれば素直に割れるが、'ZVW506000100' と
    /// 区切りなしで入力されることもある。型式部分にも数字が含まれるため
    /// 「末尾の数字列」で切ると ZVW / 506000100 と誤り、対象なのに「対象外」と
    /// 答えてしまう。届出側は範囲のプレフィックス（ZVW50）を知っているので、
    /// それを削った残りを連番として扱う。
    static func sequence(of vinInput: String, forPrefix prefix: String) -> String? {
        let vin = normalizeTypeCode(vinInput)
        let pre = normalizeTypeCode(prefix)
        guard !vin.isEmpty, !pre.isEmpty, vin.hasPrefix(pre) else { return nil }
        let seq = String(vin.dropFirst(pre.count))
        guard !seq.isEmpty, seq.allSatisfy(\.isNumber) else { return nil }
        return seq
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
        guard !trimmed.isEmpty else { return .possible }

        // 届出側のプレフィックスと噛み合えば、残りを連番として範囲判定する
        if let seq = sequence(of: trimmed, forPrefix: affected.vinPrefix) {
            guard let v = seqValue(seq),
                  let lo = seqValue(affected.vinStart),
                  let hi = seqValue(affected.vinEnd) else { return .possible }
            return (lo <= v && v <= hi) ? .confirmed : .none
        }

        // 噛み合わない場合、素直に割れて別のプレフィックスだと分かるなら対象外。
        // どちらとも言えないものは「対象外」と言い切らず要確認に倒す。
        if let parsed = split(trimmed), !parsed.seq.isEmpty,
           normalizeTypeCode(parsed.prefix) != normalizeTypeCode(affected.vinPrefix) {
            return .none
        }
        return .possible
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
