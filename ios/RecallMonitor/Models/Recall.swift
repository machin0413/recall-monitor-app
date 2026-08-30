//
//  Recall.swift
//  国土交通省 renrakuda API (mt-estraier.cgi) のレスポンスを表すモデル。
//
//  実レスポンスの構造:
//    { "data": [ {
//        "recall_data_car_mlit_notification_no": "1146490",
//        "recall_data_car_mlit_notification_date": "2020/01/29",
//        "recall_data_car_mlit_defective_device": "シートベルト",
//        "recall_data_car_mlit_situation_explanatory_text": "...",
//        "recall_data_car_mlit_measures_explanatory_text": "...",
//        "typeList":  [ { "recall_type_data_car_mlit_model_name": "DAA-ZVW50",
//                         "recall_type_data_car_mlit_car_name_code": "トヨタ",
//                         "recall_type_data_car_mlit_common_name": "プリウス",
//                         "recall_type_data_car_mlit_chassis_list": [
//                           { "mst_chassis_car_mlit_chassis_no_from": "ZVW50-6000001",
//                             "mst_chassis_car_mlit_chassis_to_to":   "ZVW50-6118168" } ] } ],
//        "typeList1" ... "typeList60": 同上（型が多い届出は分割される）
//      } ] }
//

import Foundation

/// 車台番号の範囲。1 つの型式に対して複数の不連続な範囲が入ることがある
/// （例: ZVW50-6000001〜6118168 と ZVW50-8000001〜8077900）。
struct VinRange: Hashable {
    let from: String   // "ZVW50-6000001"
    let to: String     // "ZVW50-6118168"

    var display: String { "\(from) 〜 \(to)" }
}

/// 届出の対象となる 1 型式。
struct AffectedType: Hashable {
    let typeCode: String     // 型式 "DAA-ZVW50"
    let commonName: String   // 通称名 "プリウス"
    let vinRanges: [VinRange]
}

/// リコール・改善対策の届出 1 件。
struct Recall: Identifiable, Hashable {
    let notificationNo: String   // 届出番号（端末側の既読管理に使う安定キー）
    let detailId: String         // 詳細ページ用の内部ID
    let maker: String            // メーカー（車名コード）
    let defectiveDevice: String  // 不具合装置。一覧の見出しに使う
    let notificationDate: String // "2020-01-29"
    let situation: String        // 不具合の状況
    let measures: String         // 改善措置
    let carCount: Int?           // 対象台数
    let campaignFlag: Int        // 1:リコール 2:改善対策 3:キャンペーン
    let affected: [AffectedType]
    let detailURL: URL?

    var id: String { notificationNo }

    /// 一覧に出す見出し。不具合装置が空の届出は届出番号で代替する。
    var title: String {
        defectiveDevice.isEmpty ? "届出番号 \(notificationNo)" : defectiveDevice
    }

    /// 通称名の一覧（重複除去）。"プリウス・アクア" のように表示する。
    var commonNames: [String] {
        var seen = Set<String>()
        return affected.compactMap { a in
            let n = a.commonName
            guard !n.isEmpty, seen.insert(n).inserted else { return nil }
            return n
        }
    }

    var kindLabel: String {
        switch campaignFlag {
        case 1: return "リコール"
        case 2: return "改善対策"
        default: return "サービスキャンペーン"
        }
    }
}
