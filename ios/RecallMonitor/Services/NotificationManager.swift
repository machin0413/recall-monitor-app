//
//  NotificationManager.swift
//  新規リコール検出時のローカル通知（サーバーレスで動作）。
//  APNs/FCM への移行は README 参照（将来拡張先）。
//

import UserNotifications

enum NotificationManager {

    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return settings.authorizationStatus == .authorized
        }
        // 拒否されてもアプリは使える（設定アプリから後で許可できる）
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 新規リコールのローカル通知を出す
    static func post(match: RecallMatch, vehicle: Vehicle) async {
        let content = UNMutableNotificationContent()
        content.title = match.confidence == .confirmed
            ? "【リコール該当】\(vehicle.name)"
            : "【リコール要確認】\(vehicle.name)"
        content.body = "\(match.recall.maker) \(match.recall.title)（\(match.recall.kindLabel)）"
        content.sound = .default
        content.userInfo = ["notification_no": match.recall.notificationNo,
                            "vehicle_id": vehicle.id.uuidString]

        let request = UNNotificationRequest(
            identifier: "recall-\(vehicle.id.uuidString)-\(match.recall.notificationNo)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
