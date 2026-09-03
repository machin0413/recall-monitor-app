//
//  Recall.swift
//  アプリ内で扱うリコールの表現。
//  国交省APIのレスポンスからは RecallAPIClient が組み立てる。
//

import Foundation

/// 1件のリコール届出
struct Recall: Codable, Identifiable, Equatable, Hashable {
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
struct AffectedVehicle: Codable, Equatable, Hashable {
    let typeCodes: [String]

    /// 車台番号の範囲。数値として比較できる届出のときだけ入る。
    /// 輸入車はシリアル番号（例 VF3LCYHZRLS037790）で届け出されることがあり、
    /// 連番として比較できない。その場合は3つとも空文字になる。
    let vinPrefix: String
    let vinStart: String
    let vinEnd: String

    /// 届出書に記載された車台番号の原文（表示用）。比較可否によらず入る。
    let vinFrom: String?
    let vinTo: String?

    /// 車台番号の範囲を数値比較できるか
    var hasComparableRange: Bool {
        !vinPrefix.isEmpty && !vinStart.isEmpty && !vinEnd.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case typeCodes = "type_codes"
        case vinPrefix = "vin_prefix"
        case vinStart = "vin_start"
        case vinEnd = "vin_end"
        case vinFrom = "vin_from"
        case vinTo = "vin_to"
    }
}
