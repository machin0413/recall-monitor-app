//
//  RecallDetailView.swift
//  リコール詳細（不具合の状況・改善措置・対象車両）。
//

import SwiftUI

struct RecallDetailView: View {
    let recall: Recall
    @EnvironmentObject private var vehicleStore: VehicleStore
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    /// この届出に該当する登録車両（確度つき）
    private var affectedVehicles: [(vehicle: Vehicle, confidence: MatchConfidence)] {
        vehicleStore.vehicles.compactMap { vehicle in
            guard let match = monitorStore.matchesByVehicle[vehicle.id]?
                .first(where: { $0.recall.notificationNo == recall.notificationNo }) else { return nil }
            return (vehicle, match.confidence)
        }
    }

    var body: some View {
        List {
            if !affectedVehicles.isEmpty {
                Section("あなたの車両") {
                    ForEach(affectedVehicles, id: \.vehicle.id) { entry in
                        switch entry.confidence {
                        case .confirmed:
                            Label("\(entry.vehicle.name) は対象です",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        case .needsCheck:
                            VStack(alignment: .leading, spacing: 2) {
                                Label("\(entry.vehicle.name) は型式が一致します",
                                      systemImage: "questionmark.circle.fill")
                                    .foregroundStyle(.orange)
                                Text("車台番号の範囲を判定できませんでした。販売店等でご確認ください。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("概要") {
                LabeledContent("種別", value: recall.kindLabel)
                LabeledContent("メーカー", value: recall.maker)
                LabeledContent("届出日", value: recall.notificationDate)
                LabeledContent("届出番号", value: recall.notificationNo)
                if let count = recall.carCount {
                    LabeledContent("対象台数", value: "\(count.formatted(.number)) 台")
                }
            }

            if !recall.situation.isEmpty {
                Section("不具合の状況") { Text(recall.situation).font(.body) }
            }
            if !recall.measures.isEmpty {
                Section("改善措置") { Text(recall.measures).font(.body) }
            }

            Section("対象車両") {
                ForEach(recall.affected, id: \.self) { a in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.commonName.isEmpty ? a.typeCode : "\(a.commonName)（\(a.typeCode)）")
                            .font(.subheadline.bold())
                        if a.vinRanges.isEmpty {
                            Text("車台番号の範囲は届出に記載がありません")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(a.vinRanges, id: \.self) { range in
                                Text(range.display)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let url = recall.detailURL {
                Section("詳しく見る") {
                    Link("国土交通省のページで確認", destination: url)
                }
            }
        }
        .navigationTitle(recall.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
