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
                .environmentObject(appDelegate.monitorStore)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    let monitorStore = RecallMonitorStore()
    private let bgManager = BackgroundRefreshManager()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        bgManager.register { [weak self] in
            await self?.monitorStore.refresh(notifyIfNew: true)
        }
        Task {
            await monitorStore.refresh(notifyIfNew: false)
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        bgManager.scheduleNextRefresh()
    }
}
