//
//  SettingsView.swift
//  フィードURL・更新タイミング・このアプリについて。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    @State private var feedURL = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("データソース") {
                    TextField("recalls.json のURL", text: $feedURL, axis: .vertical)
                        .font(.footnote)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    Button {
                        monitorStore.feedURLString = feedURL
                        Task { await monitorStore.refresh(notifyIfNew: true) }
                    } label: {
                        Label("今すぐ更新", systemImage: "arrow.clockwise")
                    }
                    .disabled(feedURL.isEmpty)
                } footer: {
                    if let err = monitorStore.errorMessage {
                        Text(err).foregroundStyle(.red)
                    }
                }
                Section("アプリ情報") {
                    LabeledContent("最終更新", value: monitorStore.lastUpdated.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "-")
                    LabeledContent("リコール件数", value: "\(monitorStore.recalls.count) 件")
                    LabeledContent("対応", value: "iOS 17.0+ / SwiftUI")
                    Link("データ提供: 国土交通省（外部サイト）", destination: URL(string: "https://www.mlit.go.jp/")!)
                        .font(.footnote)
                }
                Section("通知について") {
                    Text("新しくお知らせがあった車両に該当するリコールが公開されると、端末に通知します（APNs/FCM への移行は README 参照）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .onAppear { feedURL = monitorStore.feedURLString }
            .onDisappear {
                if !feedURL.isEmpty { monitorStore.feedURLString = feedURL }
            }
        }
    }
}
