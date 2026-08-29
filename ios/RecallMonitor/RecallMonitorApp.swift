//
//  RecallMonitorApp.swift
//  RecallMonitor
//
//  リコール監視アプリのエントリポイント。
//  バックグラウンド更新 (BGAppRefreshTask) とローカル通知を初期化する。
//

import SwiftUI
import BackgroundTasks

@main
struct RecallMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.vehicleStore)
                .environmentObject(appDelegate.monitorStore)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 登録車両。画面とバックグラウンド更新で同じインスタンスを共有する
    /// （画面内の @StateObject にすると、バックグラウンド更新から車両を参照できず通知が出ない）。
    let vehicleStore = VehicleStore()
    lazy var monitorStore = RecallMonitorStore(vehicleStore: vehicleStore)

    nonisolated func application(_ application: UIApplication,
                                didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            BackgroundRefreshManager.register { [monitorStore] in
                await monitorStore.refresh(notifyIfNew: true)
            }
            BackgroundRefreshManager.scheduleNextRefresh()
        }
        return true
    }

    nonisolated func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundRefreshManager.scheduleNextRefresh()
    }
}
