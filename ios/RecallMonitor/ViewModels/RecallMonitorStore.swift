//
//  RecallMonitorStore.swift
//  フィード取得・マッチング・新規通知を束ねる画面用ストア。
//

import Foundation
import Combine

@MainActor
final class RecallMonitorStore: ObservableObject {

    @Published var recalls: [Recall] = []
    @Published var matchesByVehicle: [UUID: [RecallMatch]] = [:]
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    private let vehicleStore: VehicleStore

    init(vehicleStore: VehicleStore) {
        self.vehicleStore = vehicleStore
    }

    /// フィードURL（GitHub Pages 公開後、ここを差し替える）
    var feedURLString: String {
        get { UserDefaults.standard.string(forKey: "feedURL") ?? Self.defaultFeedURL }
        set { UserDefaults.standard.set(newValue, forKey: "feedURL") }
    }

    static let defaultFeedURL = "https://machin0413.github.io/recall-monitor-app/recalls.json"

    /// 定期確認（バックグラウンド更新と通知）全体のスイッチ。
    /// オフにすると次回のバックグラウンド更新を予約しない。手動更新は常にできる。
    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoCheckKey)
            if newValue {
                BackgroundRefreshManager.scheduleNextRefresh()
            } else {
                BackgroundRefreshManager.cancelScheduledRefresh()
            }
            objectWillChange.send()
        }
    }

    private static let autoCheckKey = "autoCheckEnabled.v1"
    private let seenKey = "notifiedRecallIDs.v1"

    /// フィードを取得し、登録車両との照合と新規通知を行う
    func refresh(notifyIfNew: Bool) async {
        guard let url = URL(string: feedURLString) else {
            errorMessage = "フィードURLを設定してください（設定タブ）"
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let feed = try await RecallAPIClient(feedURL: url).fetchFeed()
            recalls = feed.recalls
            lastUpdated = Date()
            errorMessage = nil

            let vehicles = vehicleStore.vehicles
            var mapping: [UUID: [RecallMatch]] = [:]
            for vehicle in vehicles {
                mapping[vehicle.id] = RecallMatcher.matches(for: vehicle, in: feed.recalls)
            }
            matchesByVehicle = mapping

            if notifyIfNew {
                await notifyNewMatches(vehicles: vehicles)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 該当車両ごとの新規リコールだけを通知する（同じ届出は 1 台につき 1 度だけ）。
    /// 定期確認をオフにした車両は通知しない（一覧・詳細の該当表示は残す）。
    private func notifyNewMatches(vehicles: [Vehicle]) async {
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        for vehicle in vehicles where vehicle.monitoringEnabled {
            for match in matchesByVehicle[vehicle.id] ?? [] {
                let key = "\(vehicle.id.uuidString)|\(match.recall.recallId)"
                guard !seen.contains(key) else { continue }
                await NotificationManager.post(match: match, vehicle: vehicle)
                seen.insert(key)
            }
        }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
    }

    var sortedRecalls: [Recall] {
        recalls.sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
    }

    /// 全登録車両にまたがる該当リコール（重複除去済み）
    var allMatches: [RecallMatch] {
        var seen = Set<String>()
        return matchesByVehicle.values.flatMap { $0 }.filter { seen.insert($0.recall.recallId).inserted }
    }

    /// 車両を登録せずに、型式・車台番号だけで取得済みフィードを照合する。
    /// 車台番号が空でも型式だけで検索でき、その場合は結果がすべて「要確認」になる。
    func lookup(typeCode: String, vin: String) -> [RecallMatch] {
        RecallMatcher.matches(typeCode: typeCode, vin: vin, in: recalls)
            .sorted { ($0.recall.publishedAt ?? "") > ($1.recall.publishedAt ?? "") }
    }

    /// フィードが未取得なら取得する（かんたん検索の初回用）
    func loadFeedIfNeeded() async {
        guard recalls.isEmpty, !isRefreshing else { return }
        await refresh(notifyIfNew: false)
    }
}
