//
//  ContentView.swift
//  タブ構成: マイカー / リコール / 設定
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    @StateObject private var vehicleStore = VehicleStore()

    var body: some View {
        TabView {
            VehicleListView(vehicleStore: vehicleStore)
                .tabItem { Label("マイカー", systemImage: "car") }
            RecallListView()
                .tabItem { Label("リコール", systemImage: "exclamationmark.triangle") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .task {
            await NotificationManager.requestAuthorizationIfNeeded()
            await monitorStore.refresh(notifyIfNew: false, vehicles: vehicleStore.vehicles)
        }
    }
}
