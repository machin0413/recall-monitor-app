//
//  Vehicle.swift
//  ユーザーが登録する所有車両。
//

import Foundation

struct Vehicle: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String      // 登録名（例: プリウス 2020）
    var maker: String     // メーカー（例: トヨタ）
    var typeCode: String  // 型式（例: DAA-ZVW50）※車検証の型式
    var vin: String       // 車台番号（例: ZVW50-0001234）
}
