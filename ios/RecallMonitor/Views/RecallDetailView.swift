//
//  RecallDetailView.swift
//  リコール詳細（内容・対象車両・対策）。
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
                .first(where: { $0.recall.recallId == recall.recallId }) else { return nil }
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
                LabeledContent("メーカー", value: recall.maker)
                LabeledContent("届出日", value: recall.publishedAt ?? "-")
                if let content = recall.content, !content.isEmpty {
                    Text(content).font(.body)
                }
            }
            Section("対象車両") {
                ForEach(Array(recall.affected.enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.typeCodes.joined(separator: " / "))
                            .font(.subheadline.bold())
                        if !a.vinStart.isEmpty || !a.vinEnd.isEmpty {
                            Text("車台番号 \(a.vinStart) 〜 \(a.vinEnd)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let url = recall.pageUrl, let link = URL(string: url) {
                Section("詳しく見る") {
                    Link("国土交通省のページで確認", destination: link)
                }
            }
        }
        .navigationTitle(recall.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
