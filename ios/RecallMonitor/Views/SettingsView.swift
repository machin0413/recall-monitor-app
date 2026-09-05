//
//  SettingsView.swift
//  フィードURL・更新タイミング・このアプリについて。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    @ObservedObject private var configStore = RemoteConfigStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await monitorStore.refresh(notifyIfNew: true) }
                    } label: {
                        Label("今すぐ更新", systemImage: "arrow.clockwise")
                    }
                    .disabled(monitorStore.isRefreshing)
                } header: {
                    Text("データソース")
                } footer: {
                    if let err = monitorStore.errorMessage {
                        Text(err).foregroundStyle(.red)
                    } else {
                        Text("検索するたびに国土交通省のリコール情報検索へ問い合わせます。端末にデータは保存しません。")
                    }
                }
                Section("アプリ情報") {
                    LabeledContent("最終更新", value: monitorStore.lastUpdated.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "-")
                    LabeledContent("新着リコール", value: "\(monitorStore.latestRecalls.count) 件")
                    LabeledContent("対応", value: "iOS 17.0+ / SwiftUI")
                    Link("データ提供: 国土交通省（外部サイト）",
                         destination: URL(string: "https://renrakuda.mlit.go.jp/renrakuda/")!)
                        .font(.footnote)
                }
                Section {
                    LabeledContent("API設定", value: configStore.source.rawValue)
                    LabeledContent("設定の取得", value: configStore.lastFetched.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "-")
                } header: {
                    Text("接続設定")
                } footer: {
                    Text("国土交通省側の仕様が変わった場合、アプリを更新しなくても接続設定の差し替えで復旧できるようにしています。")
                }
                Section("通知について") {
                    Text("マイカーに登録した車両に該当するリコールが新しく公開されると、端末に通知します。登録していない場合、通知は行いません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
        }
    }
}
