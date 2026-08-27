//
//  RecallDetailView.swift
//  リコール詳細（内容・対象車両・対策）。
//

import SwiftUI

struct RecallDetailView: View {
    let recall: Recall
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    var body: some View {
        List {
            Section("概要") {
                LabeledContent("メーカー", value: recall.maker)
                LabeledContent("掲示日", value: recall.publishedAt ?? "-")
                if let content = recall.content {
                    Text(content)
                        .font(.body)
                }
            }
            Section("対象車両") {
                ForEach(Array(recall.affected.enumerated()), id: \.offset) { _, a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.typeCodes.joined(separator: " / "))
                            .font(.subheadline.bold())
                        Text("車台番号 \(a.vinPrefix)-\(a.vinStart) 〜 \(a.vinPrefix)-\(a.vinEnd)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if matches(affected: a) {
                            Label("あなたの車両が対象です", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
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

    private func matches(affected: AffectedVehicle) -> Bool {
        // 全登録車両の中に該当するものがいるか
        let vehicles = (monitorStore.matchingByVehicle
            .filter { $0.value.contains(where: { $0.recallId == recall.recallId }) })
        return !vehicles.isEmpty
    }
}
