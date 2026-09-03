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
                LabeledContent("届出日", value: recall.publishedAt ?? "-")
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
                        Text(chassisRangeText(a))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        switch level(of: a) {
                        case .confirmed:
                            Label("あなたの車両が対象です", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                        case .possible:
                            Label("あなたの車両が対象の可能性があります", systemImage: "questionmark.circle")
                                .font(.caption.bold())
                                .foregroundStyle(.yellow)
                        case .none:
                            EmptyView()
                        }
                    }
                }
            }
            if let url = recall.pageUrl, let link = URL(string: url) {
                Section {
                    Link("国土交通省の届出書（PDF）を開く", destination: link)
                } header: {
                    Text("詳しく見る")
                } footer: {
                    Text("車台番号が範囲内でも、仕様（変速機の違い、ターボの有無など）により対象外の場合があります。最終的な確認は自動車メーカーまたは販売会社へお問い合わせください。")
                }
            }
        }
        .navigationTitle(recall.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// この対象範囲に対する、登録車両の中で最も強い該当度。
    /// リコール単位ではなく範囲単位で判定しないと、同じ届出に複数範囲がある場合に
    /// 該当しない範囲にも警告が出てしまう。
    private func level(of affected: AffectedVehicle) -> RecallMatcher.MatchLevel {
        monitorStore.vehicles
            .map { RecallMatcher.level(typeCode: $0.typeCode, vinInput: $0.vin, affected: affected) }
            .max() ?? .none
    }

    /// 車台番号の範囲表示。届出書の原文をそのまま出す。
    private func chassisRangeText(_ a: AffectedVehicle) -> String {
        let from = a.vinFrom ?? "", to = a.vinTo ?? ""
        if from.isEmpty && to.isEmpty {
            return "車台番号の範囲は届出書（PDF）を確認してください"
        }
        return "車台番号 \(from) 〜 \(to)"
    }
}
