//
//  RecallAPIClient.swift
//  国土交通省 renrakuda の検索 API を直接呼ぶ。
//
//  注意点（実機・実データで確認済み）:
//   - エンドポイントはサイトルート直下 /mt/mt-estraier.cgi。
//     /renrakuda/mt/... に付け替えると、エラーではなく HTTP 200 + 本文 0 バイトが返る。
//   - レスポンスは Movable Type のテンプレート出力なので、JSON の前に空白・改行が入る。
//   - 配列末尾に余分なカンマが付くことがある（本家 JS も同じ正規表現で除去している）。
//   - 型リストは typeList と typeList1〜typeList60 に分割される。
//

import Foundation

enum RecallAPIError: LocalizedError {
    case badURL
    case emptyResponse
    case httpStatus(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "問い合わせ先の設定が不正です"
        case .emptyResponse:
            return "国土交通省のサーバーから応答がありませんでした。しばらくしてからお試しください。"
        case .httpStatus(let code):
            return "国土交通省のサーバーがエラーを返しました（\(code)）"
        case .decode(let detail):
            return "応答の形式が想定と異なります: \(detail)"
        }
    }
}

struct RecallAPIClient {
    var config: RemoteConfig
    var session: URLSession = .shared

    /// 型式で検索する。`modelName` は部分一致なので、確定判定は RecallMatcher 側で行う。
    /// - Parameters:
    ///   - modelName: 型式。空なら期間内の全件
    ///   - since: 届出日の下限（"YYYY/MM/DD"）。nil なら全期間
    ///   - limit: 取得上限
    func search(modelName: String?, since: String? = nil, limit: Int = 200) async throws -> [Recall] {
        guard var components = URLComponents(string: config.endpoint) else { throw RecallAPIError.badURL }

        var items = config.fixedParams.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: config.param("offset"), value: "1"))
        items.append(URLQueryItem(name: config.param("limit"), value: String(limit)))
        items.append(URLQueryItem(name: config.param("notification_date"),
                                  value: "\(since ?? "0000/00/00") 9999/12/31"))
        if let modelName, !modelName.isEmpty {
            items.append(URLQueryItem(name: config.param("model_name"), value: modelName))
        }
        components.queryItems = items

        guard let url = components.url else { throw RecallAPIError.badURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RecallAPIError.httpStatus(http.statusCode)
        }
        return try Self.parse(data, config: config)
    }

    // MARK: - パース

    static func parse(_ data: Data, config: RemoteConfig) throws -> [Recall] {
        guard var text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            // HTTP 200 でも本文が空になることがある（エンドポイント誤りなど）
            throw RecallAPIError.emptyResponse
        }
        // 配列末尾の余分なカンマを取り除く
        text = text.replacingOccurrences(of: #",\s*(\]\s*\}\s*)$"#,
                                         with: "$1",
                                         options: .regularExpression)

        guard let cleaned = text.data(using: .utf8) else { throw RecallAPIError.decode("文字コード変換に失敗") }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: cleaned)
        } catch {
            throw RecallAPIError.decode(error.localizedDescription)
        }
        guard let root = object as? [String: Any] else { throw RecallAPIError.decode("最上位が辞書ではありません") }
        guard let rows = root["data"] as? [[String: Any]] else { return [] }

        return rows.compactMap { recall(from: $0, config: config) }
    }

    private static func recall(from row: [String: Any], config: RemoteConfig) -> Recall? {
        func value(_ suffix: String) -> String {
            (row[config.dataKey(suffix)] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let notificationNo = value("notification_no")
        let detailId = value("id")
        guard !notificationNo.isEmpty || !detailId.isEmpty else { return nil }

        let affected = affectedTypes(from: row, config: config)

        return Recall(
            notificationNo: notificationNo.isEmpty ? detailId : notificationNo,
            detailId: detailId,
            maker: makerName(from: row, config: config),
            defectiveDevice: value("defective_device"),
            notificationDate: value("notification_date").replacingOccurrences(of: "/", with: "-"),
            situation: value("situation_explanatory_text"),
            measures: value("measures_explanatory_text"),
            carCount: Int(value("recall_car_count")),
            campaignFlag: Int(value("recall_campaign_flag")) ?? 1,
            affected: affected,
            detailURL: config.detailURL(id: detailId)
        )
    }

    /// メーカー名は型リスト側（車名コード）にしか入っていない。
    private static func makerName(from row: [String: Any], config: RemoteConfig) -> String {
        for item in typeItems(from: row) {
            if let name = item[config.typeKey("car_name_code")] as? String,
               !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return name.trimmingCharacters(in: .whitespaces)
            }
        }
        return "不明"
    }

    /// typeList と typeList1〜typeList60 を 1 本にまとめる。
    private static func typeItems(from row: [String: Any]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        if let base = row["typeList"] as? [[String: Any]] { items += base }
        for i in 1...60 {
            if let extra = row["typeList\(i)"] as? [[String: Any]] { items += extra }
        }
        return items
    }

    private static func affectedTypes(from row: [String: Any], config: RemoteConfig) -> [AffectedType] {
        typeItems(from: row).compactMap { item -> AffectedType? in
            let typeCode = (item[config.typeKey("model_name")] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let commonName = (item[config.typeKey("common_name")] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !typeCode.isEmpty else { return nil }

            var ranges: [VinRange] = []
            for key in ["chassis_list"] + (1...5).map({ "chassis_list\($0)" }) {
                guard let list = item[config.typeKey(key)] as? [[String: Any]] else { continue }
                for entry in list {
                    let from = (entry[config.chassisKey("chassis_no_from")] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let to = (entry[config.chassisKey("chassis_to_to")] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !from.isEmpty, !to.isEmpty {
                        ranges.append(VinRange(from: from, to: to))
                    }
                }
            }
            return AffectedType(typeCode: typeCode, commonName: commonName, vinRanges: ranges)
        }
    }
}
