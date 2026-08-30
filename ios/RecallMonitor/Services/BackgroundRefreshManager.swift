//
//  BackgroundRefreshManager.swift
//  BGAppRefreshTask による定期的なバックグラウンド更新。
//  呼び出しタイミングは OS 任せ（1日1回程度）なので、起動時の再取得も併用する。
//

import BackgroundTasks

enum BackgroundRefreshManager {
    static let taskID = "jp.recallmonitor.refresh"

    static func register(_ handler: @escaping () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            let operation = Task {
                await handler()
                refreshTask.setTaskCompleted(success: true)
                scheduleNextRefresh()
            }
            refreshTask.expirationHandler = {
                operation.cancel()
                refreshTask.setTaskCompleted(success: false)
            }
        }
    }

    /// 次回のバックグラウンド更新を予約する。
    /// 定期確認がオフのときは予約しない（設定でオンに戻したときに再予約される）。
    static func scheduleNextRefresh() {
        guard UserDefaults.standard.object(forKey: "autoCheckEnabled.v1") as? Bool ?? true else {
            cancelScheduledRefresh()
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 8 * 60 * 60) // 8時間後以降
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancelScheduledRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
    }
}
