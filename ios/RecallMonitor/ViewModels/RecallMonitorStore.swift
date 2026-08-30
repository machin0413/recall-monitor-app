//
//  RecallMonitorStore.swift
//  登録車両ごとに国交省 API へ問い合わせ、照合と新規通知を行う画面用ストア。
//

import Foundation
import Combine

@MainActor
final class RecallMonitorStore: ObservableObject {

    /// 登録車両に該当した届出（車両ID → 該当リスト）
    @Published var matchesByVehicle: [UUID: [RecallMatch]] = [:]
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?

    private let vehicleStore: VehicleStore
    private let configStore: RemoteConfigStore

    init(vehicleStore: VehicleStore, configStore: RemoteConfigStore) {
        self.vehicleStore = vehicleStore
        self.configStore = configStore
    }

    /// 定期確認（バックグラウンド更新と通知）全体のスイッチ。
    /// オフにすると次回のバックグラウンド更新を予約しない。手動更新と検索は常にできる。
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

    private var client: RecallAPIClient {
        RecallAPIClient(config: configStore.config)
    }

    // MARK: - 取得

    /// 登録車両それぞれについて型式で問い合わせ、照合と通知を行う。
    func refresh(notifyIfNew: Bool) async {
        let vehicles = vehicleStore.vehicles
        guard !vehicles.isEmpty else {
            matchesByVehicle = [:]
            lastUpdated = Date()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        await configStore.refreshIfNeeded()

        var mapping: [UUID: [RecallMatch]] = [:]
        var failures: [String] = []

        // 同じ型式の車両が複数あってもリクエストは 1 回で済ませる
        var byTypeCode: [String: [Vehicle]] = [:]
        for vehicle in vehicles {
            byTypeCode[vehicle.typeCode, default: []].append(vehicle)
        }

        await withTaskGroup(of: (String, Result<[Recall], Error>).self) { group in
            let apiClient = client
            for typeCode in byTypeCode.keys {
                group.addTask {
                    do {
                        let recalls = try await apiClient.search(modelName: typeCode)
                        return (typeCode, .success(recalls))
                    } catch {
                        return (typeCode, .failure(error))
                    }
                }
            }
            for await (typeCode, result) in group {
                switch result {
                case .success(let recalls):
                    for vehicle in byTypeCode[typeCode] ?? [] {
                        mapping[vehicle.id] = RecallMatcher.matches(for: vehicle, in: recalls)
                    }
                case .failure(let error):
                    failures.append(error.localizedDescription)
                }
            }
        }

        // 取得できた車両分だけ結果を差し替える。失敗した車両は前回の結果を残す。
        for (id, matches) in mapping {
            matchesByVehicle[id] = matches
        }
        // 削除済みの車両の結果は捨てる
        let liveIDs = Set(vehicles.map(\.id))
        matchesByVehicle = matchesByVehicle.filter { liveIDs.contains($0.key) }

        if failures.isEmpty {
            errorMessage = nil
            lastUpdated = Date()
        } else {
            errorMessage = failures.first
        }

        if notifyIfNew {
            await notifyNewMatches(vehicles: vehicles)
        }
    }

    /// 車両を登録せずに、型式・車台番号だけで国交省 API に問い合わせる。
    /// 車台番号が空でも型式だけで検索でき、その場合は結果がすべて「要確認」になる。
    func lookup(typeCode: String, vin: String) async throws -> [RecallMatch] {
        await configStore.refreshIfNeeded()
        let recalls = try await client.search(modelName: typeCode)
        return RecallMatcher.matches(typeCode: typeCode, vin: vin, in: recalls)
            .sorted { $0.recall.notificationDate > $1.recall.notificationDate }
    }

    // MARK: - 通知

    /// 該当車両ごとの新規リコールだけを通知する（同じ届出は 1 台につき 1 度だけ）。
    /// 定期確認をオフにした車両は通知しない（一覧・詳細の該当表示は残す）。
    private func notifyNewMatches(vehicles: [Vehicle]) async {
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        for vehicle in vehicles where vehicle.monitoringEnabled {
            for match in matchesByVehicle[vehicle.id] ?? [] {
                let key = "\(vehicle.id.uuidString)|\(match.recall.notificationNo)"
                guard !seen.contains(key) else { continue }
                await NotificationManager.post(match: match, vehicle: vehicle)
                seen.insert(key)
            }
        }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
    }

    /// 初回起動時は「新着」がすべて通知されてしまうため、
    /// 最初の照合結果は通知せず既読として記録する。
    func markAllAsSeen() {
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        for (vehicleID, matches) in matchesByVehicle {
            for match in matches {
                seen.insert("\(vehicleID.uuidString)|\(match.recall.notificationNo)")
            }
        }
        UserDefaults.standard.set(Array(seen), forKey: seenKey)
    }

    // MARK: - 表示用

    /// 全登録車両にまたがる該当リコール（重複除去、届出日の新しい順）
    var allMatches: [RecallMatch] {
        var seen = Set<String>()
        return matchesByVehicle.values
            .flatMap { $0 }
            .filter { seen.insert($0.recall.notificationNo).inserted }
            .sorted { $0.recall.notificationDate > $1.recall.notificationDate }
    }

    func confidence(for recall: Recall) -> MatchConfidence? {
        var best: MatchConfidence?
        for match in matchesByVehicle.values.flatMap({ $0 })
        where match.recall.notificationNo == recall.notificationNo {
            if match.confidence == .confirmed { return .confirmed }
            best = .needsCheck
        }
        return best
    }
}
