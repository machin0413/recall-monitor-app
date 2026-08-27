//
//  RecallAPIClient.swift
//  GitHub Pages / Cloudflare Pages 上の静的 recalls.json を取得する。
//

import Foundation

enum RecallAPIClientError: LocalizedError {
    case badURL
    case noData
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "フィードURLが不正です"
        case .noData: return "サーバーからデータが取得できませんでした"
        case .decode(let m): return "データ形式の解釈に失敗しました: \(m)"
        }
    }
}

struct RecallAPIClient {
    var feedURL: URL

    func fetchFeed() async throws -> RecallFeed {
        let (data, response) = try await URLSession.shared.data(from: feedURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RecallAPIClientError.noData
        }
        do {
            return try JSONDecoder().decode(RecallFeed.self, from: data)
        } catch {
            throw RecallAPIClientError.decode(error.localizedDescription)
        }
    }
}
