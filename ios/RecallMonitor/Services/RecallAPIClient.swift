//
//  RecallAPIClient.swift
//  国土交通省 renrakuda のリコール検索 API を直接呼び出す。
//
//  静的フィードを配って端末側で全件突き合わせる方式はやめ、検索のたびに
//  問い合わせる。常に最新で、端末に何も溜めない。国交省側が落ちていれば
//  検索もできないが、その場合はエラーとして正直に出す。
//
//  API:
//    https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi
//      ?blog_id=4&class=recalldatacar
//      &model_name=<型式>                      (部分一致。空なら全件)
//      &notification_date=<from> <to>          (YYYY/MM/DD 空白区切り)
//      &offset=<1始まり>&limit=<最大1000>
//      &order_by=recall_data_car_mlit_notification_date&order_condition=STRD
//
//  注意:
//   - model_name は小文字・全角では 0 件になる。RecallMatcher.canonicalTypeCode
//     を通してから渡すこと。
//   - レスポンスは JSON だが末尾カンマが混ざることがある (Movable Type 由来)。
//     そのままでは JSONDecoder が失敗するため sanitize してから解析する。
//   - 国交省側は 18時〜翌8時頃にデータ更新を行うため、その時間帯は応答が
//     遅い・繋がらないことがある。
//

import Foundation

enum RecallAPIClientError: LocalizedError {
    case badURL
    case server(Int)
    case malformedResponse
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "検索条件をURLに変換できませんでした"
        case .server(let code):
            return "国土交通省のサーバーから応答がありませんでした（HTTP \(code)）"
        case .malformedResponse:
            return "国土交通省のサーバーの応答を解釈できませんでした"
        case .decode(let m):
            return "データ形式の解釈に失敗しました: \(m)"
        }
    }
}

struct RecallAPIClient {

    static let endpoint = "https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi"
    static let pdfBase = "https://renrakuda.mlit.go.jp/renrakuda/recallpdf/"

    var session: URLSession = .shared

    /// 型式で検索する。modelName が空なら新着順の一覧になる。
    /// - Parameter modelName: 車検証の型式。canonicalTypeCode で整えてから渡す。
    func search(modelName: String = "", limit: Int = 50, offset: Int = 1) async throws -> [Recall] {
        var components = URLComponents(string: Self.endpoint)
        var items = [
            URLQueryItem(name: "blog_id", value: "4"),
            URLQueryItem(name: "class", value: "recalldatacar"),
            URLQueryItem(name: "notification_date", value: "0000/00/00 9999/12/31"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order_by", value: "recall_data_car_mlit_notification_date"),
            URLQueryItem(name: "order_condition", value: "STRD"),
        ]
        if !modelName.isEmpty {
            items.append(URLQueryItem(name: "model_name", value: modelName))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw RecallAPIClientError.badURL }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RecallAPIClientError.server(http.statusCode)
        }

        guard let body = Self.extractJSONObject(from: data) else {
            throw RecallAPIClientError.malformedResponse
        }
        do {
            let decoded = try JSONDecoder().decode(APIResponse.self, from: body)
            return decoded.data
                .filter { $0.deleteFlag != "オン" }   // 取り下げられた届出は除く
                .map { $0.toRecall() }
        } catch {
            throw RecallAPIClientError.decode(error.localizedDescription)
        }
    }

    /// 応答から JSON 本体を取り出し、末尾カンマを取り除く。
    /// 前後に空白や改行が付き、配列・オブジェクトの末尾に余分なカンマが
    /// 混ざることがあるため、そのままでは JSONDecoder が失敗する。
    static func extractJSONObject(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return Data(stripTrailingCommas(String(text[start...end])).utf8)
    }

    /// 文字列リテラルの内部を壊さないように末尾カンマ (,] や ,}) だけを除去する。
    static func stripTrailingCommas(_ s: String) -> String {
        var out = String(); out.reserveCapacity(s.count)
        var inString = false, escaped = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true; out.append(c)
            } else if c == "," {
                var j = s.index(after: i)
                while j < s.endIndex, s[j] == " " || s[j] == "\t" || s[j] == "\r" || s[j] == "\n" {
                    j = s.index(after: j)
                }
                if j < s.endIndex, s[j] == "]" || s[j] == "}" {
                    i = j                 // カンマを捨てて閉じ括弧まで飛ばす
                    continue
                }
                out.append(c)
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        return out
    }
}

// MARK: - API レスポンスの形

private struct APIResponse: Decodable {
    let data: [APIRecord]
}

private struct APIRecord: Decodable {
    let notificationNo: String?
    let notificationDate: String?
    let defectiveDevice: String?
    let situation: String?
    let measures: String?
    let campaignFlag: String?
    let deleteFlag: String?
    let typeList: [APIType]?

    enum CodingKeys: String, CodingKey {
        case notificationNo   = "recall_data_car_mlit_notification_no"
        case notificationDate = "recall_data_car_mlit_notification_date"
        case defectiveDevice  = "recall_data_car_mlit_defective_device"
        case situation        = "recall_data_car_mlit_situation_explanatory_text"
        case measures         = "recall_data_car_mlit_measures_explanatory_text"
        case campaignFlag     = "recall_data_car_mlit_recall_campaign_flag"
        case deleteFlag       = "recall_data_car_mlit_delete_flag"
        case typeList
    }

    func toRecall() -> Recall {
        let no = (notificationNo ?? "").trimmingCharacters(in: .whitespaces)
        let device = (defectiveDevice ?? "").trimmingCharacters(in: .whitespaces)
        let kind = campaignFlag == "2" ? "改善対策" : "リコール"

        var makers: [String] = [], names: [String] = []
        for t in typeList ?? [] {
            if let m = t.carName?.trimmingCharacters(in: .whitespaces),
               !m.isEmpty, !makers.contains(m) { makers.append(m) }
            if let c = t.commonName?.trimmingCharacters(in: .whitespaces),
               !c.isEmpty, !names.contains(c) { names.append(c) }
        }

        // 一覧で読んで意味が分かるように「通称名／不具合装置」を見出しにする
        let head = names.prefix(3).joined(separator: "・")
        var title = head.isEmpty ? device : (device.isEmpty ? head : "\(head)／\(device)")
        if title.isEmpty { title = "\(kind) \(no)" }
        if kind != "リコール" { title = "[\(kind)] \(title)" }

        var content = (situation ?? "").trimmingCharacters(in: .whitespaces)
        let measure = (measures ?? "").trimmingCharacters(in: .whitespaces)
        if !measure.isEmpty {
            content = content.isEmpty ? "【改善措置】\(measure)" : "\(content)\n\n【改善措置】\(measure)"
        }

        return Recall(
            recallId: no,
            maker: makers.prefix(3).joined(separator: "・"),
            title: title,
            publishedAt: (notificationDate ?? "").replacingOccurrences(of: "/", with: "-"),
            content: content,
            affected: (typeList ?? []).flatMap { $0.toAffected() },
            pageUrl: no.isEmpty ? nil : RecallAPIClient.pdfBase + no + ".pdf"
        )
    }
}

private struct APIType: Decodable {
    let carName: String?
    let modelName: String?
    let commonName: String?
    let chassisList: [APIChassis]?

    enum CodingKeys: String, CodingKey {
        case carName     = "recall_type_data_car_mlit_car_name_code"
        case modelName   = "recall_type_data_car_mlit_model_name"
        case commonName  = "recall_type_data_car_mlit_common_name"
        case chassisList = "recall_type_data_car_mlit_chassis_list"
    }

    /// 型式ごとの対象車台番号範囲を組み立てる。
    ///
    /// 国産車は 'ZVW50-6000001' のように 型式プレフィックス＋連番 なので数値比較
    /// できるが、輸入車は 'VF3LCYHZRLS037790' のようなシリアル番号で届け出られる
    /// ことがあり、連番として比較できない。その場合は範囲を空にして
    /// 「判定不能」を表す（型式一致のみで『対象の可能性あり』とし確定させない）。
    func toAffected() -> [AffectedVehicle] {
        let model = (modelName ?? "").trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return [] }

        let ranges = chassisList ?? []
        guard !ranges.isEmpty else {
            // 車台番号範囲の記載がない届出。型式だけで拾えるようにしておく。
            return [AffectedVehicle(typeCodes: [model], vinPrefix: "", vinStart: "", vinEnd: "",
                                    vinFrom: nil, vinTo: nil)]
        }

        return ranges.map { c in
            let rawFrom = (c.from ?? "").trimmingCharacters(in: .whitespaces)
            let rawTo = (c.to ?? "").trimmingCharacters(in: .whitespaces)
            let parsedFrom = RecallMatcher.split(rawFrom)
            let parsedTo = RecallMatcher.split(rawTo)
            let comparable = parsedFrom != nil && parsedTo != nil
                && !parsedFrom!.seq.isEmpty && !parsedTo!.seq.isEmpty
                && parsedFrom!.prefix == parsedTo!.prefix

            return AffectedVehicle(
                typeCodes: [model],
                vinPrefix: comparable ? parsedFrom!.prefix : "",
                vinStart: comparable ? parsedFrom!.seq : "",
                vinEnd: comparable ? parsedTo!.seq : "",
                vinFrom: rawFrom.isEmpty ? nil : rawFrom,
                vinTo: rawTo.isEmpty ? nil : rawTo
            )
        }
    }
}

private struct APIChassis: Decodable {
    let from: String?
    let to: String?

    enum CodingKeys: String, CodingKey {
        case from = "mst_chassis_car_mlit_chassis_no_from"
        // API 側のキー名が chassis_to_to になっている（誤記だが変更できない）
        case to   = "mst_chassis_car_mlit_chassis_to_to"
    }
}
