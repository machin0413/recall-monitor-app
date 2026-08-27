//
//  RecallListView.swift
//  最新リコールの一覧（登録車両に該当するものは強調表示）。
//

import SwiftUI

struct RecallListView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    private var relevantIDs: Set<String> {
        var ids = Set<String>()
        for recalls in monitorStore.matchingByVehicle.values {
            for r in recalls { ids.insert(r.recallId) }
        }
        return ids
    }

    var body: some View {
        NavigationStack {
            Group {
                if monitorStore.recalls.isEmpty {
                    ContentUnavailableView(
                        "リコールデータがありません",
                        systemImage: "tray",
                        description: Text(monitorStore.isRefreshing ? "更新中…" : "「今すぐ更新」で最新データを取得できます")
                    )
                } else {
                    List(monitorStore.sortedRecalls) { recall in
                        NavigationLink(value: recall) {
                            RecallRow(recall: recall, isRelevant: relevantIDs.contains(recall.recallId))
                        }
                    }
                    .refreshable {
                        await monitorStore.refresh(notifyIfNew: true)
                    }
                }
            }
            .navigationTitle("リコール")
            .navigationDestination(for: Recall.self) { RecallDetailView(recall: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if monitorStore.isRefreshing {
                        ProgressView()
                    }
                }
            }
        }
    }
}

private struct RecallRow: View {
    let recall: Recall
    let isRelevant: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if isRelevant {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(recall.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
            }
            Text(recall.maker)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("掲示日: \(recall.publishedAt ?? "-")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
