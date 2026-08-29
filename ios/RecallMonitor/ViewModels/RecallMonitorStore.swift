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

    /// 該当車両ごとの新規リコールだけを通知する（同じ届出は 1 台につき 1 度だけ）
    private func notifyNewMatches(vehicles: [Vehicle]) async {
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        for vehicle in vehicles {
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
}
