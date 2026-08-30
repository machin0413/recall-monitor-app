//
//  RecallSearchView.swift
//  車両を登録せずに、型式・車台番号だけでその場で調べる画面。
//  廃止された JASPA アプリの「リコール情報検索」に相当する入口。
//
//  国交省 API を直接呼ぶので、事前のデータダウンロードは不要。
//

import SwiftUI

struct RecallSearchView: View {
    @EnvironmentObject private var monitorStore: RecallMonitorStore

    @State private var typeCode = ""
    @State private var vin = ""
    @State private var results: [RecallMatch] = []
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var isRegistering = false

    private var canSearch: Bool {
        !typeCode.trimmingCharacters(in: .whitespaces).isEmpty && !isSearching
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("型式（例: DAA-ZVW50）", text: $typeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("車台番号（任意・例: ZVW50-6001234）", text: $vin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("車検証の記載")
                } footer: {
                    Text("型式だけでも調べられます。車台番号まで入れると、対象範囲に入っているかまで判定できます。")
                }

                Section {
                    Button { Task { await search() } } label: {
                        if isSearching {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("国土交通省に問い合わせ中…")
                            }
                        } else {
                            Label("調べる", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(!canSearch)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                if hasSearched, errorMessage == nil {
                    resultSection
                }
            }
            .navigationTitle("調べる")
            .navigationDestination(for: Recall.self) { RecallDetailView(recall: $0) }
            .sheet(isPresented: $isRegistering) {
                NavigationStack {
                    VehicleEditView(vehicle: nil,
                                    prefilledTypeCode: typeCode,
                                    prefilledVin: vin)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if results.isEmpty {
            Section {
                Label("該当するリコール届出はありません", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("入力した型式に一致する届出は見つかりませんでした。型式は車検証のとおり（例: DAA-ZVW50）に入力してください。")
            }
        } else {
            Section {
                ForEach(results) { match in
                    NavigationLink(value: match.recall) {
                        RecallRow(match: match)
                    }
                }
            } header: {
                Text("該当 \(results.count) 件")
            } footer: {
                if vin.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("車台番号を入れていないため、すべて「要確認」として表示しています。")
                }
            }

            Section {
                Button { isRegistering = true } label: {
                    Label("この車両を登録して通知を受け取る", systemImage: "bell.badge")
                }
            } footer: {
                Text("登録すると、新しく該当するリコールが出たときに通知します。通知が不要なら、車両ごとに定期確認をオフにできます。")
            }
        }
    }

    private func search() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await monitorStore.lookup(typeCode: typeCode, vin: vin)
            hasSearched = true
        } catch {
            errorMessage = error.localizedDescription
            hasSearched = false
        }
    }
}
