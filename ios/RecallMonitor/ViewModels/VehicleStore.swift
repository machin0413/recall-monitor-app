//
//  VehicleStore.swift
//  登録車両の永続化（UserDefaults + JSON）。
//

import Foundation
import Combine

final class VehicleStore: ObservableObject {

    /// アプリ全体で共有する唯一のインスタンス。
    /// 画面（マイカー一覧・編集）とバックグラウンド更新が同じ登録車両を
    /// 見る必要があるため、インスタンスを分けてはいけない。
    static let shared = VehicleStore()

    @Published var vehicles: [Vehicle] {
        didSet { save() }
    }

    private static let key = "vehicles.v1"
    private let defaults = UserDefaults.standard

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Vehicle].self, from: data) {
            vehicles = decoded
        } else {
            vehicles = []
        }
    }

    func add(_ vehicle: Vehicle) { vehicles.append(vehicle) }
    func remove(at offsets: IndexSet) { vehicles.remove(atOffsets: offsets) }

    private func save() {
        if let data = try? JSONEncoder().encode(vehicles) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
