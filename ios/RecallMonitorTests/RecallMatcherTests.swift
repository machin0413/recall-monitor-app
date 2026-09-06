//
//  RecallMatcherTests.swift
//  照合ロジックのテスト。
//
//  ここは「自分の車が対象か」を判断する中核で、実際に 2 回バグを出している。
//  どちらも見逃し（対象なのに対象外と答える）方向だった。見つけた不具合は
//  必ずここに回帰テストとして残すこと。
//

import XCTest
@testable import RecallMonitor

final class RecallMatcherTests: XCTestCase {

    // MARK: - 型式の正規化とキー

    func test_型式は全角と小文字と区切りを吸収する() {
        XCTAssertEqual(RecallMatcher.normalizeTypeCode("daa-zvw50"), "DAAZVW50")
        XCTAssertEqual(RecallMatcher.normalizeTypeCode("ＤＡＡ－ＺＶＷ５０"), "DAAZVW50")
        XCTAssertEqual(RecallMatcher.normalizeTypeCode("DAA ZVW50"), "DAAZVW50")
        // 日本語キーボードでは「-」が長音符になる
        XCTAssertEqual(RecallMatcher.normalizeTypeCode("DAA\u{30FC}ZVW50"), "DAAZVW50")
    }

    func test_排ガス記号つきは記号なしの本体もキーに持つ() {
        XCTAssertEqual(RecallMatcher.typeCodeKeys("BC-ZRT10A"), ["BCZRT10A", "ZRT10A"])
        XCTAssertEqual(RecallMatcher.typeCodeKeys("DAA-ZVW50"), ["DAAZVW50", "ZVW50"])
    }

    func test_記号なしの型式はそれ自身だけをキーに持つ() {
        XCTAssertEqual(RecallMatcher.typeCodeKeys("ZRT10A"), ["ZRT10A"])
    }

    func test_空の型式はキーを持たない() {
        XCTAssertTrue(RecallMatcher.typeCodeKeys("").isEmpty)
        XCTAssertTrue(RecallMatcher.typeCodeKeys("   ").isEmpty)
    }

    // MARK: - 型式の一致

    /// 回帰: 車検証どおり 'BC-ZRT10A' と入力すると、'ZRT10A' で登録された
    /// 1999 年の届出が見えなくなっていた。記号の有無は双方向に吸収する。
    func test_排ガス記号の有無を双方向に吸収する() {
        XCTAssertTrue(RecallMatcher.typeCodeMatches("ZRT10A", "BC-ZRT10A"))
        XCTAssertTrue(RecallMatcher.typeCodeMatches("BC-ZRT10A", "ZRT10A"))
        XCTAssertTrue(RecallMatcher.typeCodeMatches("DAA-ZVW50", "ZVW50"))
        XCTAssertTrue(RecallMatcher.typeCodeMatches("ZVW50", "DAA-ZVW50"))
    }

    func test_表記ゆれを吸収する() {
        XCTAssertTrue(RecallMatcher.typeCodeMatches("DAA-ZVW50", "daa zvw50"))
        XCTAssertTrue(RecallMatcher.typeCodeMatches("DAA-ZVW50", "ＤＡＡ－ＺＶＷ５０"))
        XCTAssertTrue(RecallMatcher.typeCodeMatches("DAA-ZVW50", "DAA\u{30FC}ZVW50"))
    }

    func test_別の型式とは一致しない() {
        XCTAssertFalse(RecallMatcher.typeCodeMatches("DAA-ZVW50", "DAA-ZVW51"))
        XCTAssertFalse(RecallMatcher.typeCodeMatches("DAA-ZVW50", "ZVW51"))
    }

    /// 部分一致だった頃は 'GG' が 'XXX-GGYY' にも当たり、無関係な車が
    /// 「対象の可能性あり」と並んでいた。キー方式では当たらない。
    func test_部分文字列では一致しない() {
        XCTAssertFalse(RecallMatcher.typeCodeMatches("XXX-GGYY", "GG"))
        XCTAssertFalse(RecallMatcher.typeCodeMatches("DAA-ZVW50", "ZVW5"))
        XCTAssertFalse(RecallMatcher.typeCodeMatches("DAA-ZVW50", "DAA"))
    }

    func test_空の入力はどの届出にも一致しない() {
        XCTAssertFalse(RecallMatcher.typeCodeMatches("DAA-ZVW50", ""))
    }

    // MARK: - API へ渡すクエリ

    /// API の絞り込みは部分一致なので、記号つきのまま投げると記号なしで
    /// 登録された届出が返ってこない。本体を投げて網を広く張る。
    func test_APIへは排ガス記号を落とした本体を渡す() {
        XCTAssertEqual(RecallMatcher.searchQuery(for: "BC-ZRT10A"), "ZRT10A")
        XCTAssertEqual(RecallMatcher.searchQuery(for: "DAA-ZVW50"), "ZVW50")
        XCTAssertEqual(RecallMatcher.searchQuery(for: "ZRT10A"), "ZRT10A")
        // 小文字・全角のままだと API は 0 件を返すので、ここで整える
        XCTAssertEqual(RecallMatcher.searchQuery(for: "daa-zvw50"), "ZVW50")
        XCTAssertEqual(RecallMatcher.searchQuery(for: "ＤＡＡ－ＺＶＷ５０"), "ZVW50")
        XCTAssertEqual(RecallMatcher.searchQuery(for: "DAA\u{30FC}ZVW50"), "ZVW50")
    }

    // MARK: - 車台番号の分割

    /// 回帰: 区切りなしの 'ZVW506000100' を「末尾の数字列」で切ると
    /// ZVW / 506000100 と誤り、対象なのに「対象外」と答えていた。
    /// 届出側のプレフィックスを起点に削る。
    func test_区切りの有無によらず連番を取り出せる() {
        for vin in ["ZVW50-6000100", "ZVW506000100", "ZVW50 6000100",
                    "ZVW50\u{30FC}6000100", "ＺＶＷ５０－６０００１００"] {
            XCTAssertEqual(RecallMatcher.sequence(of: vin, forPrefix: "ZVW50"), "6000100",
                           "入力 \(vin) の連番が取り出せない")
        }
    }

    func test_プレフィックスが噛み合わなければ連番は取れない() {
        XCTAssertNil(RecallMatcher.sequence(of: "ABC12-0000001", forPrefix: "ZVW50"))
        XCTAssertNil(RecallMatcher.sequence(of: "わからない", forPrefix: "ZVW50"))
        XCTAssertNil(RecallMatcher.sequence(of: "", forPrefix: "ZVW50"))
    }

    // MARK: - 該当度

    /// 実データ: 届出1146490（プリウス／シートベルト）。
    /// 1 つの型式に不連続な範囲が 2 つある。
    private let range1 = AffectedVehicle(
        typeCodes: ["DAA-ZVW50"], vinPrefix: "ZVW50",
        vinStart: "6000001", vinEnd: "6118168",
        vinFrom: "ZVW50-6000001", vinTo: "ZVW50-6118168")
    private let range2 = AffectedVehicle(
        typeCodes: ["DAA-ZVW50"], vinPrefix: "ZVW50",
        vinStart: "8000001", vinEnd: "8077900",
        vinFrom: "ZVW50-8000001", vinTo: "ZVW50-8077900")
    /// 輸入車。シリアル番号で届け出られており連番として比較できない。
    private let serialRange = AffectedVehicle(
        typeCodes: ["3DA-P24YH01"], vinPrefix: "", vinStart: "", vinEnd: "",
        vinFrom: "VR3UDYHZSMJ832616", vinTo: "VR3UDYHZSPJ557604")

    func test_車台番号が範囲内なら確定する() {
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-6000100", affected: range1), .confirmed)
    }

    func test_範囲の境界を含む() {
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-6000001", affected: range1), .confirmed)
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-6118168", affected: range1), .confirmed)
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-6118169", affected: range1), .none)
    }

    /// 不連続な範囲の隙間（6118169〜7999999）は対象ではない。
    /// 範囲をまとめて最小〜最大で見ると、ここを誤って対象にしてしまう。
    func test_不連続な範囲の隙間は対象にしない() {
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-7000000", affected: range1), .none)
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-7000000", affected: range2), .none)
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-8000500", affected: range2), .confirmed)
    }

    func test_型式が違えば対象外() {
        XCTAssertEqual(RecallMatcher.level(typeCode: "ZZZ99",
                                           vinInput: "", affected: range1), .none)
    }

    // 判断がつかないものは .none に落とさず .possible に倒す。
    // リコールは見逃しの実害が誤検知より大きい。

    func test_車台番号がなければ可能性ありに倒す() {
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "", affected: range1), .possible)
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "   ", affected: range1), .possible)
    }

    func test_読み取れない車台番号は可能性ありに倒す() {
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "わからない", affected: range1), .possible)
    }

    func test_範囲を比較できない届出は確定させない() {
        XCTAssertEqual(RecallMatcher.level(typeCode: "3DA-P24YH01",
                                           vinInput: "VR3UDYHZSMJ832616", affected: serialRange),
                       .possible)
        XCTAssertFalse(serialRange.hasComparableRange)
    }

    func test_明らかに別のプレフィックスなら対象外にする() {
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ABC12-0000001", affected: range1), .none)
    }

    // MARK: - 届出単位の判定

    func test_複数の範囲のうち最も強い該当度を返す() {
        let recall = Recall(recallId: "R1", maker: "M", title: "T", publishedAt: "2020-01-29",
                            content: nil, affected: [range1, range2], pageUrl: nil)
        // range2 の範囲内。range1 では対象外だが、届出としては確定
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-8000500", in: recall), .confirmed)
        // どちらの範囲にも入らない
        XCTAssertEqual(RecallMatcher.level(typeCode: "DAA-ZVW50",
                                           vinInput: "ZVW50-7000000", in: recall), .none)
    }

    func test_該当度の強さは確定が最上位() {
        XCTAssertTrue(RecallMatcher.MatchLevel.confirmed > .possible)
        XCTAssertTrue(RecallMatcher.MatchLevel.possible > .none)
        XCTAssertEqual([RecallMatcher.MatchLevel.possible, .none, .confirmed].max(), .confirmed)
    }
}
