//
//  VehicleListView.swift
//  登録車両の一覧と、車両ごとのリコール該当バッジ。
//

import SwiftUI

struct VehicleListView: View {
    @ObservedObject var vehicleStore: VehicleStore
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    var body: some View {
        NavigationStack {
            Group {
                if vehicleStore.vehicles.isEmpty {
                    ContentUnavailableView(
                        "車両を追加してください",
                        systemImage: "car",
                        description: Text("車検証の型式・車台番号を登録すると、リコールを自動でお知らせします")
                    )
                } else {
                    List {
                        ForEach(vehicleStore.vehicles) { vehicle in
                            NavigationLink(value: vehicle) {
                                VehicleRow(vehicle: vehicle)
                            }
                        }
                        .onDelete(perform: vehicleStore.remove)
                    }
                }
            }
            .navigationTitle("マイカー")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        VehicleEditView(vehicleStore: vehicleStore, vehicle: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: Vehicle.self) { vehicle in
                VehicleEditView(vehicleStore: vehicleStore, vehicle: vehicle)
            }
        }
        .onReceive(monitorStore.$matchingByVehicle) { _ in }
    }
}

private struct VehicleRow: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    let vehicle: Vehicle

    private var hitCount: Int {
        monitorStore.matchingByVehicle[vehicle.id]?.count ?? 0
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(vehicle.name).font(.headline)
                Text("\(vehicle.maker) / \(vehicle.typeCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("車台番号 \(vehicle.vin)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if hitCount > 0 {
                Label("\(hitCount)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
        }
    }
}
