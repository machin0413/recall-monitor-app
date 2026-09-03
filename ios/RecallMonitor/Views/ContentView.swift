//
//  ContentView.swift
//  タブ構成: 検索 / マイカー / リコール / 設定
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    @ObservedObject private var vehicleStore = VehicleStore.shared

    var body: some View {
        TabView {
            // 主動線。登録なしでいきなり調べられるよう先頭に置く。
            RecallSearchView()
                .tabItem { Label("検索", systemImage: "magnifyingglass") }
            VehicleListView(vehicleStore: vehicleStore)
                .tabItem { Label("マイカー", systemImage: "car") }
            RecallListView()
                .tabItem { Label("リコール", systemImage: "exclamationmark.triangle") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .task {
            await NotificationManager.requestAuthorizationIfNeeded()
            await monitorStore.refresh(notifyIfNew: false)
        }
    }
}
