//
//  SettingsView.swift
//  定期確認の設定・フィードURL・このアプリについて。
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var vehicleStore: VehicleStore
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    @State private var feedURL = ""
    @State private var autoCheck = true

    /// 定期確認の対象になっている車両の台数
    private var monitoredCount: Int {
        vehicleStore.vehicles.filter(\.monitoringEnabled).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("定期確認", isOn: $autoCheck)
                        .onChange(of: autoCheck) { _, newValue in
                            monitorStore.autoCheckEnabled = newValue
                        }
                } header: {
                    Text("自動でお知らせ")
                } footer: {
                    if autoCheck {
                        Text(vehicleStore.vehicles.isEmpty
                             ? "車両を登録すると、新しく該当するリコールが出たときに通知します。"
                             : "登録した \(vehicleStore.vehicles.count) 台のうち \(monitoredCount) 台を定期確認しています。車両ごとの切り替えは各車両の編集画面から行えます。")
                    } else {
                        Text("バックグラウンドでの確認と通知を停止します。「調べる」タブとリコール一覧はこれまでどおり使えます。")
                    }
                }

                Section {
                    Button {
                        Task { await monitorStore.refresh(notifyIfNew: true) }
                    } label: {
                        if monitorStore.isRefreshing {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("更新中…")
                            }
                        } else {
                            Label("今すぐ更新", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(monitorStore.isRefreshing)
                } footer: {
                    if let err = monitorStore.errorMessage {
                        Text(err).foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("recalls.json のURL", text: $feedURL, axis: .vertical)
                        .font(.footnote)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("データソース")
                } footer: {
                    Text("通常は変更不要です。")
                }

                Section("アプリ情報") {
                    LabeledContent("最終更新", value: monitorStore.lastUpdated.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? "-")
                    LabeledContent("リコール件数", value: "\(monitorStore.recalls.count) 件")
                    LabeledContent("対応", value: "iOS 17.0+ / SwiftUI")
                    Link("データ提供: 国土交通省（外部サイト）",
                         destination: URL(string: "https://renrakuda.mlit.go.jp/renrakuda/top.html")!)
                        .font(.footnote)
                }
            }
            .navigationTitle("設定")
            .onAppear {
                feedURL = monitorStore.feedURLString
                autoCheck = monitorStore.autoCheckEnabled
            }
            .onDisappear {
                if !feedURL.isEmpty { monitorStore.feedURLString = feedURL }
            }
        }
    }
}
