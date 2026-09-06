//
//  RecallAPIClientTests.swift
//  国交省APIレスポンスの解析のテスト。
//
//  実際の応答を Fixtures/ に固定ファイルとして記録し、ネットワーク無しで走らせる。
//  「外界が変わっていないか」は scripts/check_api.py（カナリア）の担当で、
//  ここは「記録した応答を正しく読めるか」だけを見る。
//

import XCTest
@testable import RecallMonitor

final class RecallAPIClientTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"),
                               "固定ファイル \(name).json が見つからない")
        return try Data(contentsOf: url)
    }

    private func parse(_ name: String, limit: Int = 10) throws -> RecallAPIClient.SearchResult {
        try RecallAPIClient.parse(fixture(name),
                                  pdfBase: APIConfig.builtIn.pdfBase,
                                  limit: limit)
    }

    // MARK: - 末尾カンマの除去

    // 応答は JSON だが配列やオブジェクトの末尾に余分なカンマが混ざることがある
    // （Movable Type のテンプレート出力）。素の JSONDecoder は失敗する。

    func test_配列とオブジェクトの末尾カンマを取り除く() {
        XCTAssertEqual(RecallAPIClient.stripTrailingCommas("[1,2,]"), "[1,2]")
        XCTAssertEqual(RecallAPIClient.stripTrailingCommas("{\"a\":1,}"), "{\"a\":1}")
        XCTAssertEqual(RecallAPIClient.stripTrailingCommas("[1, 2 ,\n ]"), "[1, 2 ]")
        XCTAssertEqual(RecallAPIClient.stripTrailingCommas("[[1,],]"), "[[1]]")
    }

    func test_正常なJSONは変えない() {
        XCTAssertEqual(RecallAPIClient.stripTrailingCommas("[1,2]"), "[1,2]")
        XCTAssertEqual(RecallAPIClient.stripTrailingCommas("{\"a\":1,\"b\":2}"), "{\"a\":1,\"b\":2}")
    }

    /// 文字列リテラルの中身は書き換えてはいけない。単純な正規表現で
    /// 一括置換すると、本文に「,]」を含む届出を壊す。
    func test_文字列リテラルの中身は壊さない() {
        let input = "{\"note\":\"配列は ,] で終わる\"}"
        XCTAssertEqual(RecallAPIClient.stripTrailingCommas(input), input)
        let escaped = "{\"note\":\"引用符 \\\" のあとに ,} \"}"
        XCTAssertEqual(RecallAPIClient.stripTrailingCommas(escaped), escaped)
    }

    func test_前後の空白や改行があってもJSON本体を取り出せる() throws {
        let data = Data("\n\n  {\"data\":[]}  \n".utf8)
        let extracted = try XCTUnwrap(RecallAPIClient.extractJSONObject(from: data))
        XCTAssertEqual(String(decoding: extracted, as: UTF8.self), "{\"data\":[]}")
    }

    // MARK: - 実応答の解析

    func test_実応答を届出として読み取れる() throws {
        let result = try parse("search-zrt10a")
        XCTAssertEqual(result.recalls.count, 4)

        let oldest = try XCTUnwrap(result.recalls.first { $0.recallId == "1105960" })
        XCTAssertEqual(oldest.publishedAt, "1999-12-09")
        XCTAssertEqual(oldest.maker, "カワサキ")
        XCTAssertTrue(oldest.title.contains("ゼファー"), "通称名が見出しに入っていない: \(oldest.title)")
        XCTAssertFalse(oldest.content?.isEmpty ?? true)
        // 届出書 PDF は届出番号から組み立てる
        XCTAssertEqual(oldest.pageUrl,
                       "https://renrakuda.mlit.go.jp/renrakuda/recallpdf/1105960.pdf")
    }

    /// 回帰: 車検証どおり 'BC-ZRT10A' と入力すると 3 件しか出ず、
    /// 'ZRT10A' で登録された 1999 年の届出が見えなくなっていた。
    func test_排ガス記号つきで入力しても記号なしの届出を取りこぼさない() throws {
        let recalls = try parse("search-zrt10a").recalls
        let matched = recalls.filter {
            RecallMatcher.level(typeCode: "BC-ZRT10A", vinInput: "", in: $0) != .none
        }
        XCTAssertEqual(matched.count, 4, "記号つきの入力で取りこぼしている")
        XCTAssertTrue(matched.contains { $0.recallId == "1105960" },
                      "1999年の届出1105960（型式 ZRT10A で登録）が拾えていない")

        // 記号なしで入力しても結果は変わらない
        let withoutSymbol = recalls.filter {
            RecallMatcher.level(typeCode: "ZRT10A", vinInput: "", in: $0) != .none
        }
        XCTAssertEqual(withoutSymbol.map(\.recallId).sorted(),
                       matched.map(\.recallId).sorted())
    }

    /// 回帰: 対象型式は typeList に 32 件までしか入らず、超過分が
    /// typeList1〜typeList60 に分割される。typeList だけ読むと、
    /// 対象車種の多い大規模リコールで型式を丸ごと取りこぼす。
    func test_分割されたtypeListをすべて集約する() throws {
        let result = try parse("search-split-typelist")
        let recall = try XCTUnwrap(result.recalls.first { $0.recallId == "1242110" })

        let codes = Set(recall.affected.flatMap(\.typeCodes))
        XCTAssertEqual(codes.count, 35, "typeList(32) と分割分(3) の合計が集約されていない")
        XCTAssertTrue(codes.contains("7CF-LE73WVE"),
                      "分割分にしか現れない型式が拾えていない")
        // 分割分の型式でも該当と判定できる
        XCTAssertNotEqual(RecallMatcher.level(typeCode: "7CF-LE73WVE", vinInput: "", in: recall),
                          .none)
    }

    // MARK: - 打ち切りの検出

    func test_返却件数が上限に達したら打ち切りとみなす() throws {
        // 固定ファイルは 4 件。上限 4 なら打ち切りの可能性あり
        XCTAssertTrue(try parse("search-zrt10a", limit: 4).isTruncated)
        XCTAssertFalse(try parse("search-zrt10a", limit: 10).isTruncated)
    }

    // MARK: - 設定

    func test_内蔵の既定値は必要な項目を備えている() {
        let config = APIConfig.builtIn
        XCTAssertTrue(config.endpoint.hasPrefix("https://"))
        XCTAssertTrue(config.pdfBase.hasPrefix("https://"))
        XCTAssertEqual(config.paramNames.modelName, "model_name")
        XCTAssertNotNil(config.query["blog_id"])
        XCTAssertNotNil(config.query["class"])
        XCTAssertNil(config.notice)
    }

    func test_設定をJSONから読み書きできる() throws {
        let json = Data("""
        {"endpoint":"https://example.test/x","pdf_base":"https://example.test/pdf/",
         "query":{"a":"1"},"param_names":{"model_name":"m","offset":"o","limit":"l"},
         "notice":"点検中です"}
        """.utf8)
        let config = try JSONDecoder().decode(APIConfig.self, from: json)
        XCTAssertEqual(config.endpoint, "https://example.test/x")
        XCTAssertEqual(config.paramNames.modelName, "m")
        XCTAssertEqual(config.notice, "点検中です")

        // キャッシュのために往復させても壊れない
        let restored = try JSONDecoder().decode(
            APIConfig.self, from: try JSONEncoder().encode(config))
        XCTAssertEqual(restored, config)
    }
}
