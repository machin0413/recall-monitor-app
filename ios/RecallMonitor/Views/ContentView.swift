//
//  ContentView.swift
//  タブ構成: マイカー / リコール / 設定
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    var body: some View {
        TabView {
            VehicleListView()
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
