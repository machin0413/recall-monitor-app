//
//  RecallSearchView.swift
//  マイカー登録なしで、型式（＋任意で車台番号）から該当リコールを調べる画面。
//  「思い立って一度だけ調べる」利用が大半を占めるため、これをアプリの主動線とする。
//  マイカー登録は「継続して通知を受け取りたい人だけの任意ステップ」に位置づける。
//
//  検索のたびに国交省APIへ問い合わせる。端末には何も溜めない。
//

import SwiftUI

struct RecallSearchView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore
    @ObservedObject private var vehicleStore = VehicleStore.shared

    @State private var typeCode = ""
    @State private var vin = ""

    @State private var hits: [Hit] = []
    @State private var isSearching = false
    @State private var errorText: String?
    /// 一度でも検索したか（未検索と 0 件を区別する）
    @State private var searchedQuery: String?

    private struct Hit: Identifiable {
        let recall: Recall
        let level: RecallMatcher.MatchLevel
        var id: String { recall.recallId }
    }

    private var trimmedTypeCode: String {
        typeCode.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("型式（例: DAA-ZVW50）", text: $typeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { search() }
                    TextField("車台番号（任意・例: ZVW50-0001234）", text: $vin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { search() }
                } header: {
                    Text("車検証の記載")
                } footer: {
                    Text("型式だけでも調べられます。車台番号も入れると、対象かどうかが確定します。")
                }

                Section {
                    Button {
                        search()
                    } label: {
                        HStack {
                            Label("検索", systemImage: "magnifyingglass")
                            if isSearching {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(trimmedTypeCode.isEmpty || isSearching)
                }

                resultSection

                if searchedQuery != nil && !trimmedTypeCode.isEmpty {
                    Section {
                        NavigationLink {
                            VehicleEditView(
                                vehicleStore: vehicleStore,
                                vehicle: Vehicle(name: "", maker: "",
                                                 typeCode: trimmedTypeCode, vin: vin)
                            )
                        } label: {
                            Label("この車をマイカーに登録して通知を受け取る", systemImage: "bell.badge")
                        }
                    } footer: {
                        Text("登録すると、新しく該当するリコールが公開されたときに通知します。登録しなくても検索はいつでも使えます。")
                    }
                }
            }
            .navigationTitle("リコール検索")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let errorText {
            Section {
                Label(errorText, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.red)
            } footer: {
                Text("国土交通省のサイトは 18時〜翌8時頃にデータ更新を行うため、繋がりにくいことがあります。時間をおいて試してください。")
            }
        } else if searchedQuery == nil {
            Section {
                Label("型式を入力して検索してください", systemImage: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if hits.isEmpty {
            Section {
                Label("該当するリコールは見つかりませんでした", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("型式は車検証のとおり、排ガス記号から入力してください（例: DAA-ZVW50）。")
            }
        } else {
            Section("検索結果 \(hits.count) 件") {
                ForEach(hits) { hit in
                    NavigationLink {
                        RecallDetailView(recall: hit.recall)
                    } label: {
                        SearchResultRow(recall: hit.recall, level: hit.level)
                    }
                }
            }
        }
    }

    private func search() {
        let query = trimmedTypeCode
        guard !query.isEmpty, !isSearching else { return }
        isSearching = true
        errorText = nil
        Task {
            defer { isSearching = false }
            do {
                let found = try await monitorStore.search(typeCode: query, vin: vin)
                hits = found.map { Hit(recall: $0.recall, level: $0.level) }
                searchedQuery = query
            } catch {
                hits = []
                errorText = error.localizedDescription
            }
        }
    }
}

private struct SearchResultRow: View {
    let recall: Recall
    let level: RecallMatcher.MatchLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch level {
            case .confirmed:
                Label("対象です", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            case .possible:
                Label("対象の可能性あり（車台番号で確認してください）", systemImage: "questionmark.circle")
                    .font(.caption.bold())
                    .foregroundStyle(.yellow)
            case .none:
                EmptyView()
            }
            Text(recall.title)
                .font(.subheadline.bold())
                .lineLimit(2)
            Text(recall.maker)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("届出日: \(recall.publishedAt ?? "-")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
