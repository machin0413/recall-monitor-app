//
//  RemoteConfig.swift
//  国交省 API の呼び出し設定を GitHub Pages から取得する。
//
//  国交省サイトの仕様が変わったとき、アプリを更新せずに config.json だけ直せば
//  全端末が復旧できるようにするための仕組み。取得に失敗したら組み込みの既定値を使う。
//

import Foundation

struct RemoteConfig: Codable, Equatable {
    var endpoint: String
    var fixedParams: [String: String]
    var paramNames: [String: String]
    var fieldPrefixes: [String: String]
    var detailURLTemplate: String
    var sourceURL: String
    var notice: String?

    enum CodingKeys: String, CodingKey {
        case endpoint
        case fixedParams = "fixed_params"
        case paramNames = "param_names"
        case fieldPrefixes = "field_prefixes"
        case detailURLTemplate = "detail_url_template"
        case sourceURL = "source_url"
        case notice
    }

    /// 2026-08 時点で確認済みの値。config.json が取れないときはこれを使う。
    static let builtIn = RemoteConfig(
        endpoint: "https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi",
        fixedParams: [
            "blog_id": "4",
            "class": "recalldatacar",
            "order_by": "recall_data_car_mlit_notification_date",
            "order_condition": "STRD",
        ],
        paramNames: [
            "model_name": "model_name",
            "notification_date": "notification_date",
            "offset": "offset",
            "limit": "limit",
        ],
        fieldPrefixes: [
            "data": "recall_data_car_mlit_",
            "type": "recall_type_data_car_mlit_",
            "chassis": "mst_chassis_car_mlit_",
        ],
        detailURLTemplate: "https://renrakuda.mlit.go.jp/renrakuda/ris-detail-car.html?id={id}",
        sourceURL: "https://renrakuda.mlit.go.jp/renrakuda/top.html",
        notice: nil
    )

    // MARK: - 参照用ヘルパ

    func param(_ key: String) -> String { paramNames[key] ?? key }
    func dataKey(_ suffix: String) -> String { (fieldPrefixes["data"] ?? "") + suffix }
    func typeKey(_ suffix: String) -> String { (fieldPrefixes["type"] ?? "") + suffix }
    func chassisKey(_ suffix: String) -> String { (fieldPrefixes["chassis"] ?? "") + suffix }

    func detailURL(id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return URL(string: detailURLTemplate.replacingOccurrences(of: "{id}", with: encoded))
    }
}

@MainActor
final class RemoteConfigStore: ObservableObject {
    @Published private(set) var config: RemoteConfig

    /// config.json の配信元。設定画面から差し替えられる。
    static let defaultConfigURL = "https://machin0413.github.io/recall-monitor-app/config.json"

    private static let cacheKey = "remoteConfig.v1"
    private static let fetchedAtKey = "remoteConfigFetchedAt.v1"
    /// 1 日 1 回だけ取りにいけば十分
    private static let minInterval: TimeInterval = 24 * 60 * 60

    var configURLString: String {
        get { UserDefaults.standard.string(forKey: "configURL") ?? Self.defaultConfigURL }
        set { UserDefaults.standard.set(newValue, forKey: "configURL") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(RemoteConfig.self, from: data) {
            config = cached
        } else {
            config = .builtIn
        }
    }

    /// 起動時に呼ぶ。失敗しても既存の設定を使い続けるので、呼び出し側でのエラー処理は不要。
    func refreshIfNeeded(force: Bool = false) async {
        let last = UserDefaults.standard.object(forKey: Self.fetchedAtKey) as? Date
        if !force, let last, Date().timeIntervalSince(last) < Self.minInterval { return }
        guard let url = URL(string: configURLString) else { return }

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadRevalidatingCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            let fetched = try JSONDecoder().decode(RemoteConfig.self, from: data)
            config = fetched
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
            UserDefaults.standard.set(Date(), forKey: Self.fetchedAtKey)
        } catch {
            // 取得できなくてもキャッシュ or 組み込み既定値で動作を続ける
        }
    }
}
