//
//  RecallMonitorStore.swift
//  国交省APIへの問い合わせと、登録車両との照合をまとめる画面用ストア。
//
//  静的フィードを端末に溜める方式はやめ、必要なときに毎回問い合わせる。
//  常に最新が返り、端末側に古いデータが残らない。国交省側が落ちていれば
//  検索できないが、その場合はエラーとして表示する。
//

import Foundation
import Combine

@MainActor
final class RecallMonitorStore: ObservableObject {

    /// リコールタブに出す新着（型式によらない直近の届出）
    @Published var latestRecalls: [Recall] = []
    @Published var matchingByVehicle: [UUID: [Recall]] = [:]
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    /// 1台の車両に対して引く件数の上限。1つの型式に紐づく届出は多くても数十件。
    private let perVehicleLimit = 200
    /// 新着一覧の件数
    private let latestLimit = 50

    private let client = RecallAPIClient()
    private let vehicleStore: VehicleStore
    private var cancellables = Set<AnyCancellable>()
    private let seenKey = "notifiedRecallIDs.v1"

    /// 現在の登録車両（詳細画面などの表示用）
    var vehicles: [Vehicle] { vehicleStore.vehicles }

    init(vehicleStore: VehicleStore = .shared) {
        self.vehicleStore = vehicleStore
        // 車両の追加・編集・削除で該当リコールを引き直す
        vehicleStore.$vehicles
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refreshVehicleMatches(notifyIfNew: true) }
                }
            }
            .store(in: &cancellables)
    }

    /// 新着の取得と、登録車両の照合をまとめて行う
    func refresh(notifyIfNew: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            latestRecalls = try await client.search(limit: latestLimit)
            lastUpdated = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshVehicleMatches(notifyIfNew: notifyIfNew)
    }

    /// 登録車両ごとに型式で問い合わせ、該当リコールを更新する
    func refreshVehicleMatches(notifyIfNew: Bool) async {
        let registered = vehicleStore.vehicles
        guard !registered.isEmpty else {
            matchingByVehicle = [:]
            return
        }
        var mapping: [UUID: [Recall]] = [:]
        for vehicle in registered {
            do {
                mapping[vehicle.id] = try await search(typeCode: vehicle.typeCode,
                                                       vin: vehicle.vin).map(\.recall)
            } catch {
                // 1台失敗しても他の車両は続ける。前回の結果は消さずに残す。
                mapping[vehicle.id] = matchingByVehicle[vehicle.id]
                errorMessage = error.localizedDescription
            }
        }
        matchingByVehicle = mapping

        if notifyIfNew {
            notifyNewMatches(vehicles: registered)
        }
    }

    /// 型式（＋任意の車台番号）で検索し、該当度つきで返す。
    /// 検索画面と登録車両の照合の両方がここを通る。
    func search(typeCode: String,
                vin: String) async throws -> [(recall: Recall, level: RecallMatcher.MatchLevel)] {
        // API は小文字・全角では 0 件になるため、必ず整えてから渡す
        let query = RecallMatcher.canonicalTypeCode(typeCode)
        guard !query.isEmpty else { return [] }

        let recalls = try await client.search(modelName: query, limit: perVehicleLimit)
        return recalls
            .compactMap { recall -> (recall: Recall, level: RecallMatcher.MatchLevel)? in
                let level = RecallMatcher.level(typeCode: typeCode, vinInput: vin, in: recall)
                return level == .none ? nil : (recall, level)
            }
            // 確定（対象）を先に、次に届出日の新しい順
            .sorted {
                $0.level != $1.level
                    ? $0.level > $1.level
                    : ($0.recall.publishedAt ?? "") > ($1.recall.publishedAt ?? "")
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
}
