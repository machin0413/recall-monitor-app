//
//  RecallMonitorStore.swift
//  フィード取得・マッチング・新規通知を束ねる画面用ストア。
//

import Foundation
import Combine

@MainActor
final class RecallMonitorStore: ObservableObject {

    @Published var recalls: [Recall] = []
    @Published var matchingByVehicle: [UUID: [Recall]] = [:]
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    /// フィードURL（GitHub Pages 公開後、ここを差し替える）
    var feedURLString: String {
        get { UserDefaults.standard.string(forKey: "feedURL") ?? Self.defaultFeedURL }
        set { UserDefaults.standard.set(newValue, forKey: "feedURL") }
    }

    static let defaultFeedURL = "https://YOUR-USERNAME.github.io/recall-monitor/recalls.json"

    private let seenKey = "notifiedRecallIDs.v1"
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// フィードを取得し、登録車両との照合と新規通知を行う
    func refresh(notifyIfNew: Bool, vehicles: [Vehicle] = []) async {
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

            var mapping: [UUID: [Recall]] = [:]
            for vehicle in vehicles {
                mapping[vehicle.id] = RecallMatcher.recalls(matching: vehicle, in: feed.recalls)
            }
            matchingByVehicle = mapping

            if notifyIfNew {
                notifyNewMatches(vehicles: vehicles)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 新しくマッチしたリコールにだけ通知する
    private func notifyNewMatches(vehicles: [Vehicle]) {
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        for vehicle in vehicles {
            for recall in matchingByVehicle[vehicle.id] ?? [] where !seen.contains(recall.recallId) {
                Task { await NotificationManager.post(recall: recall, vehicle: vehicle) }
                seen.insert(recall.recallId)
            }
        }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
    }

    var sortedRecalls: [Recall] {
        recalls.sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
    }
}
