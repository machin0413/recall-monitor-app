//
//  VehicleStore.swift
//  登録車両の永続化（UserDefaults + JSON）。
//  アプリ起動時に AppDelegate が生成し、画面とバックグラウンド更新の双方から参照する。
//

import Foundation
import Combine

@MainActor
final class VehicleStore: ObservableObject {
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
