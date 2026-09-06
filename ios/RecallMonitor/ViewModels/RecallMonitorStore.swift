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

    /// 1台の車両に対して引く件数の上限。
    /// API へは排ガス記号を落とした本体を投げるため網が広くなる。取りこぼすと
    /// 通知が飛ばなくなるので、検索画面より多めに取る。
    private let perVehicleLimit = 500
    /// 新着一覧の件数
    private let latestLimit = 50

    private let configStore = RemoteConfigStore.shared
    private let vehicleStore: VehicleStore

    /// 呼び出しのたびに最新の設定でクライアントを組む。
    /// config.json が更新されれば、次の検索から新しい設定が効く。
    private var client: RecallAPIClient { RecallAPIClient(config: configStore.config) }

    /// 利用者向けのお知らせ（config.json から。通常は nil）
    var notice: String? { configStore.config.notice }
    private var cancellables = Set<AnyCancellable>()
    /// 通知済みの (車両, 届出) の組。届出番号だけで持つと、同じリコールに
    /// 2 台が該当したとき 2 台目の通知が抑止されてしまう。
    private let seenKey = "notifiedVehicleRecallPairs.v2"
    /// 既に基準取りを済ませた車両。登録直後の一斉通知を避けるために使う。
    private let baselinedKey = "baselinedVehicleIDs.v1"

    /// 現在の登録車両（詳細画面などの表示用）
    var vehicles: [Vehicle] { vehicleStore.vehicles }

    init(vehicleStore: VehicleStore = .shared) {
        self.vehicleStore = vehicleStore
        // 設定が差し替わったら画面にも反映されるよう、変更を上流に流す
        configStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
        // API の呼び方が変わっていないかを先に確認する。
        // 取得に失敗しても内蔵値かキャッシュで動き続ける。
        await configStore.refresh()
        do {
            latestRecalls = try await client.search(limit: latestLimit).recalls
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
        var truncatedVehicles: [String] = []
        for vehicle in registered {
            do {
                let outcome = try await search(typeCode: vehicle.typeCode, vin: vehicle.vin)
                mapping[vehicle.id] = outcome.matches.map(\.recall)
                if outcome.truncated {
                    // 上限に達している = 該当を取りこぼしている可能性がある。
                    // 通知の抜けに直結するので黙って捨てない。
                    truncatedVehicles.append(vehicle.name)
                }
            } catch {
                // 1台失敗しても他の車両は続ける。前回の結果は消さずに残す。
                mapping[vehicle.id] = matchingByVehicle[vehicle.id]
                errorMessage = error.localizedDescription
            }
        }
        matchingByVehicle = mapping
        if !truncatedVehicles.isEmpty {
            errorMessage = "該当が多いため一部しか確認できていません（\(truncatedVehicles.joined(separator: "・"))）。"
                + "型式を車検証のとおり入力し直してください。"
        }

        if notifyIfNew {
            notifyNewMatches(vehicles: registered)
        }
    }

    /// 検索の結果。打ち切りが起きたかどうかも返す。
    struct SearchOutcome {
        let matches: [RecallMatch]
        /// API の上限に達しており、表示できていない届出がありうる
        let truncated: Bool
    }

    /// 型式（＋任意の車台番号）で検索し、該当度つきで返す。
    /// 検索画面と登録車両の照合の両方がここを通る。
    func search(typeCode: String, vin: String, limit: Int? = nil) async throws -> SearchOutcome {
        // API へは排ガス記号を落とした本体を投げる。'BC-ZRT10A' のまま投げると
        // 'ZRT10A' で登録された届出が返ってこず、取りこぼす。
        // 小文字・全角のままだと 0 件になるので、整形もここで済ませる。
        let query = RecallMatcher.searchQuery(for: typeCode)
        guard !query.isEmpty else { return SearchOutcome(matches: [], truncated: false) }

        let result = try await client.search(modelName: query, limit: limit ?? perVehicleLimit)
        let matches = result.recalls
            .compactMap { recall -> RecallMatch? in
                let level = RecallMatcher.level(typeCode: typeCode, vinInput: vin, in: recall)
                return level == .none ? nil : RecallMatch(recall: recall, level: level)
            }
            // 確定（対象）を先に、次に届出日の新しい順
            .sorted {
                $0.level != $1.level
                    ? $0.level > $1.level
                    : ($0.recall.publishedAt ?? "") > ($1.recall.publishedAt ?? "")
            }
        return SearchOutcome(matches: matches, truncated: result.isTruncated)
    }

    /// 新しく該当したリコールにだけ通知する。
    ///
    /// 登録した直後の車両については通知しない。その時点の該当は画面に出ており、
    /// 古い車だと十数件を一斉に鳴らすことになる。UI も「新しく該当するリコールが
    /// 公開されたときに通知します」と約束しているので、既存分は既読として記録するに
    /// とどめ、以後に増えた分だけ通知する。
    private func notifyNewMatches(vehicles: [Vehicle]) {
        let defaults = UserDefaults.standard
        var seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        var baselined = Set(defaults.stringArray(forKey: baselinedKey) ?? [])

        for vehicle in vehicles {
            let matches = matchingByVehicle[vehicle.id] ?? []
            let vehicleKey = vehicle.id.uuidString

            guard baselined.contains(vehicleKey) else {
                // 登録直後。既存の該当は既読にするだけで鳴らさない。
                for recall in matches { seen.insert(Self.seenPair(vehicle, recall)) }
                baselined.insert(vehicleKey)
                continue
            }
            for recall in matches where !seen.contains(Self.seenPair(vehicle, recall)) {
                Task { await NotificationManager.post(recall: recall, vehicle: vehicle) }
                seen.insert(Self.seenPair(vehicle, recall))
            }
        }
        defaults.set(Array(seen), forKey: seenKey)
        defaults.set(Array(baselined), forKey: baselinedKey)
    }

    /// 通知済みかどうかは (車両, 届出) の組で持つ
    private static func seenPair(_ vehicle: Vehicle, _ recall: Recall) -> String {
        "\(vehicle.id.uuidString)|\(recall.recallId)"
    }
}
