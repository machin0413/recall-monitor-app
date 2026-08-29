//
//  Recall.swift
//  backend/fetch_recalls.py が生成する recalls.json のデコードモデル。
//  スキーマ変更時は backend 側と必ず同期すること。
//

import Foundation

/// フィード全体（generated_at, feed_updated_at, recalls）
struct RecallFeed: Codable {
    let generatedAt: String
    let feedUpdatedAt: String?
    let recalls: [Recall]

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case feedUpdatedAt = "feed_updated_at"
        case recalls
    }
}

/// 1件のリコール届出
struct Recall: Codable, Identifiable, Hashable {
    let recallId: String
    let maker: String
    let title: String
    let publishedAt: String?
    let content: String?
    let affected: [AffectedVehicle]
    let pageUrl: String?

    var id: String { recallId }

    enum CodingKeys: String, CodingKey {
        case recallId = "recall_id"
        case maker
        case title
        case publishedAt = "published_at"
        case content
        case affected
        case pageUrl = "page_url"
    }
}

/// 対象車両（型式コード・車台番号範囲）
struct AffectedVehicle: Codable, Hashable {
    let typeCodes: [String]
    let vinPrefix: String
    let vinStart: String
    let vinEnd: String

    enum CodingKeys: String, CodingKey {
        case typeCodes = "type_codes"
        case vinPrefix = "vin_prefix"
        case vinStart = "vin_start"
        case vinEnd = "vin_end"
    }
}
