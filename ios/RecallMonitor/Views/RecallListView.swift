//
//  RecallListView.swift
//  最新リコールの一覧（登録車両に該当するものは強調表示）。
//

import SwiftUI

struct RecallListView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    private var confidenceByRecallID: [String: MatchConfidence] {
        var result: [String: MatchConfidence] = [:]
        for match in monitorStore.matchesByVehicle.values.flatMap({ $0 }) {
            // 1 件でも「対象確定」があればそちらを優先して表示する
            if result[match.recall.recallId] != .confirmed {
                result[match.recall.recallId] = match.confidence
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if monitorStore.recalls.isEmpty {
                    ContentUnavailableView(
                        "リコールデータがありません",
                        systemImage: "tray",
                        description: Text(monitorStore.isRefreshing ? "更新中…" : "下に引いて更新してください")
                    )
                } else {
                    let confidences = confidenceByRecallID
                    List(monitorStore.sortedRecalls) { recall in
                        NavigationLink(value: recall) {
                            RecallRow(recall: recall, confidence: confidences[recall.recallId])
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
    let confidence: MatchConfidence?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                switch confidence {
                case .confirmed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .needsCheck:
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
                case .none:
                    EmptyView()
                }
                Text(recall.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
            }
            Text(recall.maker)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("届出日: \(recall.publishedAt ?? "-")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
