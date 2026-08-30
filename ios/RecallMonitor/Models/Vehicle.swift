//
//  Vehicle.swift
//  ユーザーが登録する所有車両。
//  画面遷移の値として使うため Hashable に準拠する。
//

import Foundation

struct Vehicle: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String       // 登録名（例: プリウス 2020）
    var maker: String      // メーカー（例: トヨタ）
    var typeCode: String   // 型式（例: DAA-ZVW50）※車検証の型式
    var vin: String        // 車台番号（例: ZVW50-0001234）

    /// 定期確認（バックグラウンド更新時の通知）の対象にするか。
    /// 「登録はしておきたいが通知は要らない」という使い方に対応する。
    /// オフでも一覧・詳細の該当表示は通常どおり行う。
    var monitoringEnabled: Bool = true

    init(id: UUID = UUID(),
         name: String,
         maker: String,
         typeCode: String,
         vin: String,
         monitoringEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.maker = maker
        self.typeCode = typeCode
        self.vin = vin
        self.monitoringEnabled = monitoringEnabled
    }

    /// monitoringEnabled を持たない旧バージョンの保存データも読めるようにする。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        maker = try c.decode(String.self, forKey: .maker)
        typeCode = try c.decode(String.self, forKey: .typeCode)
        vin = try c.decode(String.self, forKey: .vin)
        monitoringEnabled = try c.decodeIfPresent(Bool.self, forKey: .monitoringEnabled) ?? true
    }
}
