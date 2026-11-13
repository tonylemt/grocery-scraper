import Charts
import SwiftUI

private func money(_ row: PriceRow) -> String {
    row.price.formatted(.currency(code: "CAD")) + (row.unit.isEmpty ? "" : " \(row.unit)")
}

struct ContentView: View {
    @State private var store = PriceStore()

    var body: some View {
        NavigationStack {
            List {
                if let error = store.error {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                }
                ForEach(store.items, id: \.self) { item in
                    NavigationLink(value: item) {
                        HStack {
                            Text(item)
                            Spacer()
                            if let best = store.current(item).first {
                                VStack(alignment: .trailing) {
                                    Text(money(best)).monospacedDigit()
                                    Text(best.store).font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("no price today").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.rows.isEmpty && store.error == nil { ProgressView() }
            }
            .navigationTitle("Grocery Prices")
            .navigationDestination(for: String.self) { ItemDetail(item: $0, store: store) }
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
            .safeAreaInset(edge: .bottom) {
                if let date = store.latestDate {
                    Text("Prices from \(date)").font(.footnote).foregroundStyle(.secondary).padding(8)
                }
            }
        }
    }
}

struct ItemDetail: View {
    let item: String
    let store: PriceStore

    var body: some View {
        let history = store.history(item)
        let current = store.current(item)
        List {
            Section("Cheapest match per store") {
                Chart(history, id: \.self) { row in
                    LineMark(x: .value("Day", row.day, unit: .day), y: .value("Price", row.price))
                        .foregroundStyle(by: .value("Store", row.store))
                    PointMark(x: .value("Day", row.day, unit: .day), y: .value("Price", row.price))
                        .foregroundStyle(by: .value("Store", row.store))
                }
                .chartYAxis {
                    AxisMarks(format: .currency(code: "CAD"))
                }
                .frame(height: 260)
                .padding(.vertical, 8)
            }
            Section("Today") {
                ForEach(current, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.store).font(.headline)
                            Spacer()
                            Text(money(row)).monospacedDigit()
                        }
                        Text(row.name).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(item)
        .navigationBarTitleDisplayMode(.inline)
    }
}
