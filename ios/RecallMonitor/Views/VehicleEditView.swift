//
//  VehicleEditView.swift
//  車両の登録・編集フォーム（型式・車台番号は車検証と同じ表記で入力）。
//

import SwiftUI
import UIKit

struct VehicleEditView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var vehicleStore = VehicleStore()

    let vehicle: Vehicle?
    @State private var name = ""
    @State private var maker = ""
    @State private var typeCode = ""
    @State private var vin = ""

    var body: some View {
        Form {
            Section("車両情報") {
                TextField("登録名（例: プリウス）", text: $name)
                TextField("メーカー（例: トヨタ）", text: $maker)
            }
            Section("車検証の記載") {
                TextField("型式（例: DAA-ZVW50）", text: $typeCode)
                    .textInputAutocapitalization(.characters)
                TextField("車台番号（例: ZVW50-0001234）", text: $vin)
                    .textInputAutocapitalization(.characters)
            }
            Section(footer: Text("型式・車台番号はお手元の車検証（または車検証アプリ）で確認できます")) {
                Button("保存") { save() }
                    .disabled(name.isEmpty || typeCode.isEmpty || vin.isEmpty)
            }
        }
        .navigationTitle(vehicle == nil ? "車両を追加" : "車両を編集")
        .onAppear(perform: fill)
    }

    private func fill() {
        guard let vehicle else { return }
        name = vehicle.name
        maker = vehicle.maker
        typeCode = vehicle.typeCode
        vin = vehicle.vin
    }

    private func save() {
        let newVehicle = Vehicle(
            id: vehicle?.id ?? UUID(),
            name: name,
            maker: maker,
            typeCode: typeCode,
            vin: vin
        )
        if vehicle != nil {
            if let i = vehicleStore.vehicles.firstIndex(where: { $0.id == newVehicle.id }) {
                vehicleStore.vehicles[i] = newVehicle
            }
        } else {
            vehicleStore.add(newVehicle)
        }
        dismiss()
    }
}
