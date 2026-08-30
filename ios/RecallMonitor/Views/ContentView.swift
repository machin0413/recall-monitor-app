//
//  ContentView.swift
//  タブ構成: 調べる / マイカー / リコール / 設定
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vehicleStore: VehicleStore
    @EnvironmentObject private var configStore: RemoteConfigStore
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    /// 初回起動では既存の該当リコールを一斉に通知してしまわないよう、
    /// 最初の照合結果は既読として記録するだけにする。
    @AppStorage("hasCompletedFirstCheck.v1") private var hasCompletedFirstCheck = false

    var body: some View {
        TabView {
            RecallSearchView()
                .tabItem { Label("調べる", systemImage: "magnifyingglass") }
            VehicleListView()
                .tabItem { Label("マイカー", systemImage: "car") }
            MatchedRecallListView()
                .tabItem { Label("リコール", systemImage: "exclamationmark.triangle") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .task {
            await configStore.refreshIfNeeded()
            await NotificationManager.requestAuthorizationIfNeeded()
            await monitorStore.refresh(notifyIfNew: false)
            if !hasCompletedFirstCheck {
                monitorStore.markAllAsSeen()
                hasCompletedFirstCheck = true
            }
        }
    }
}
