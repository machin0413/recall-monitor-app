//
//  RemoteConfig.swift
//  API のエンドポイントとパラメータ名を、アプリの外から差し替えられるようにする。
//
//  アプリは国交省の API を直接呼んでおり、そこは公開仕様ではない。パスや
//  パラメータ名が変わればアプリは即座に全端末で使えなくなる。埋め込みのままだと
//  復旧に App Store 審査を挟むことになり、数日～1週間は使えない状態が続く。
//
//  そこでリポジトリの config.json を起動時に読み、そこにあればそれを使う。
//  仕様変更時は config.json を直して push するだけで、全端末が数分で復旧する。
//
//  配信は raw.githubusercontent.com をそのまま使う。GitHub Pages も
//  デプロイ手順も不要で、リポジトリにファイルを1つ置くだけで済む。
//
//  吸収できないもの: レスポンスのフィールド名が変わった場合。これはデコーダの
//  修正が要るので、アプリの更新が必要になる。config.json は「どこへ何を送るか」
//  だけを扱う。
//

import Foundation

/// API の呼び出し方を決める設定
struct APIConfig: Codable, Equatable {
    var endpoint: String
    var pdfBase: String
    /// 毎回同じ値で送る固定パラメータ
    var query: [String: String]
    /// 呼び出しごとに値が変わるパラメータの名前
    var paramNames: ParamNames
    /// 利用者に伝えたいことがあれば入る。API が壊れたときの周知に使う
    var notice: String?

    struct ParamNames: Codable, Equatable {
        var modelName: String
        var offset: String
        var limit: String

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case offset
            case limit
        }
    }

    enum CodingKeys: String, CodingKey {
        case endpoint
        case pdfBase = "pdf_base"
        case query
        case paramNames = "param_names"
        case notice
    }

    /// config.json を取得できないときに使う既定値。
    /// config.json の中身と一致させておくこと。
    static let builtIn = APIConfig(
        endpoint: "https://renrakuda.mlit.go.jp/mt/mt-estraier.cgi",
        pdfBase: "https://renrakuda.mlit.go.jp/renrakuda/recallpdf/",
        query: [
            "blog_id": "4",
            "class": "recalldatacar",
            "notification_date": "0000/00/00 9999/12/31",
            "order_by": "recall_data_car_mlit_notification_date",
            "order_condition": "STRD",
        ],
        paramNames: ParamNames(modelName: "model_name", offset: "offset", limit: "limit"),
        notice: nil
    )
}

@MainActor
final class RemoteConfigStore: ObservableObject {

    /// 設定の出どころ。設定画面に出して、切り分けをしやすくする。
    enum Source: String {
        case builtIn = "アプリ内蔵"
        case cached  = "前回取得したもの"
        case remote  = "最新を取得済み"
    }

    static let shared = RemoteConfigStore()

    /// 設定の配信元。ここだけは差し替えられない（取りに行く先を設定で決められないため）
    static let configURL = URL(string:
        "https://raw.githubusercontent.com/machin0413/recall-monitor-app/main/config.json")!

    @Published private(set) var config: APIConfig
    @Published private(set) var source: Source
    @Published private(set) var lastFetched: Date?

    private static let cacheKey = "apiConfig.v1"
    private static let fetchedAtKey = "apiConfigFetchedAt.v1"

    init() {
        // 起動直後から検索できるよう、まずキャッシュ（無ければ内蔵）で始める。
        // 最新の取得は refresh() で非同期に行い、取れたら差し替える。
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(APIConfig.self, from: data) {
            config = cached
            source = .cached
            lastFetched = defaults.object(forKey: Self.fetchedAtKey) as? Date
        } else {
            config = .builtIn
            source = .builtIn
            lastFetched = nil
        }
    }

    /// config.json を取得して差し替える。失敗しても既存の設定をそのまま使い続ける。
    func refresh() async {
        var request = URLRequest(url: Self.configURL)
        // これは障害からの復旧経路なので、キャッシュに一切頼らない。
        // 条件付き GET だと URLSession と CDN のキャッシュを掴んで、直したはずの
        // 設定が古いまま返ることがある（実際に起きた）。設定は数百バイトで
        // 起動時に1回しか取らないため、毎回取り直しても損はしない。
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return
            }
            let fetched = try JSONDecoder().decode(APIConfig.self, from: data)
            guard !fetched.endpoint.isEmpty, URL(string: fetched.endpoint) != nil else { return }

            config = fetched
            source = .remote
            lastFetched = Date()
            UserDefaults.standard.set(try? JSONEncoder().encode(fetched), forKey: Self.cacheKey)
            UserDefaults.standard.set(lastFetched, forKey: Self.fetchedAtKey)
        } catch {
            // 取得できなくても機能は落とさない。内蔵値かキャッシュで動き続ける。
        }
    }
}
