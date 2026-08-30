//
//  VehicleListView.swift
//  登録車両の一覧と、車両ごとのリコール該当バッジ。
//

import SwiftUI

struct VehicleListView: View {
    @EnvironmentObject private var vehicleStore: VehicleStore
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    @State private var isAddingVehicle = false

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
                        .onDelete { vehicleStore.remove(at: $0) }
                    }
                }
            }
            .navigationTitle("マイカー")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingVehicle = true
                    } label: {
                        Label("車両を追加", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: Vehicle.self) { vehicle in
                VehicleEditView(vehicle: vehicle)
            }
            .sheet(isPresented: $isAddingVehicle) {
                NavigationStack {
                    VehicleEditView(vehicle: nil)
                }
            }
        }
    }
}

private struct VehicleRow: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    let vehicle: Vehicle

    private var matches: [RecallMatch] {
        monitorStore.matchesByVehicle[vehicle.id] ?? []
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(vehicle.name).font(.headline)
                    if !vehicle.monitoringEnabled {
                        Image(systemName: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("定期確認オフ")
                    }
                }
                Text("\(vehicle.maker) / \(vehicle.typeCode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("車台番号 \(vehicle.vin)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if !matches.isEmpty {
                let confirmed = matches.filter { $0.confidence == .confirmed }.count
                Label("\(matches.count)", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(confirmed > 0 ? .orange : .yellow)
            }
        }
    }
}
