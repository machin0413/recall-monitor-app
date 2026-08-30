//
//  MatchedRecallListView.swift
//  登録車両に該当するリコールの一覧。
//
//  国交省の全届出（1万件超）をそのまま並べても実用にならないため、
//  この画面は「自分の車に関係するもの」だけを出す。
//  型式を指定した任意検索は「調べる」タブが担当する。
//

import SwiftUI

struct MatchedRecallListView: View {
    @EnvironmentObject private var vehicleStore: VehicleStore
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    var body: some View {
        NavigationStack {
            Group {
                if vehicleStore.vehicles.isEmpty {
                    ContentUnavailableView(
                        "車両が未登録です",
                        systemImage: "car",
                        description: Text("マイカーを登録すると、該当するリコールをここにまとめます")
                    )
                } else if monitorStore.allMatches.isEmpty {
                    ContentUnavailableView(
                        monitorStore.isRefreshing ? "確認中…" : "該当するリコールはありません",
                        systemImage: monitorStore.isRefreshing ? "arrow.clockwise" : "checkmark.circle",
                        description: Text(monitorStore.isRefreshing
                                          ? "国土交通省のデータを確認しています"
                                          : "登録した車両に該当する届出は見つかりませんでした")
                    )
                } else {
                    List(monitorStore.allMatches) { match in
                        NavigationLink(value: match.recall) {
                            RecallRow(match: match)
                        }
                    }
                    .refreshable { await monitorStore.refresh(notifyIfNew: true) }
                }
            }
            .navigationTitle("リコール")
            .navigationDestination(for: Recall.self) { RecallDetailView(recall: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if monitorStore.isRefreshing { ProgressView() }
                }
            }
        }
    }
}

/// 一覧の 1 行。「調べる」タブと共通で使う。
struct RecallRow: View {
    let match: RecallMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                switch match.confidence {
                case .confirmed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .needsCheck:
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
                }
                Text(match.recall.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(match.recall.kindLabel) ・ 届出日 \(match.recall.notificationDate)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        let names = match.recall.commonNames.prefix(3).joined(separator: "・")
        return names.isEmpty ? match.recall.maker : "\(match.recall.maker) \(names)"
    }
}
