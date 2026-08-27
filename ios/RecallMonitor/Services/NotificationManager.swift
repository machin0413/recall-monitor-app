//
//  NotificationManager.swift
//  新規リコール検出時のローカル通知（サーバーレスで動作）。
//  APNs/FCM への移行は README 参照（将来拡張先）。
//

import UserNotifications

enum NotificationManager {

    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // 拒否でもアプリは使える（設定画面から再要求可能）
        }
    }

    /// 新規リコールのローカル通知を出す
    static func post(recall: Recall, vehicle: Vehicle) async {
        let content = UNMutableNotificationContent()
        content.title = "【リコール】\(vehicle.name)"
        content.body = "\(recall.maker) \(recall.title)"
        content.sound = .default
        content.userInfo = ["recall_id": recall.recallId]

        let request = UNNotificationRequest(
            identifier: "recall-\(recall.recallId)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
