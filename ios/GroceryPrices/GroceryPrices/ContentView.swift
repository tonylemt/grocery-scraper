import Charts
import SwiftUI

private func cad(_ value: Double) -> String { value.formatted(.currency(code: "CAD")) }

/// Shelf price as advertised, e.g. "$4.88 /lb".
private func shelf(_ row: PriceRow) -> String {
    cad(row.price) + (row.unit.isEmpty ? "" : " \(row.unit)")
}

/// "$10.76/kg", or nil when the size is unknown.
private func perUnit(_ row: PriceRow) -> String? {
    guard let up = row.unitPrice, let per = row.per else { return nil }
    return "\(cad(up))/\(per)"
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
                                    Text(perUnit(best) ?? shelf(best)).monospacedDigit()
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
        let per = current.compactMap(\.per).first ?? history.compactMap(\.per).first ?? "unit"
        List {
            Section("Cheapest per \(per), by store") {
                if history.isEmpty {
                    Text("No product sizes could be read yet.").foregroundStyle(.secondary)
                } else {
                    Chart(history, id: \.self) { row in
                        LineMark(x: .value("Day", row.day, unit: .day), y: .value("Price per \(per)", row.unitPrice!))
                            .foregroundStyle(by: .value("Store", row.store))
                        PointMark(x: .value("Day", row.day, unit: .day), y: .value("Price per \(per)", row.unitPrice!))
                            .foregroundStyle(by: .value("Store", row.store))
                    }
                    .chartYAxis {
                        AxisMarks(format: .currency(code: "CAD"))
                    }
                    .frame(height: 260)
                    .padding(.vertical, 8)
                }
            }
            Section {
                ForEach(current, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.store).font(.headline)
                            Spacer()
                            Text(perUnit(row) ?? "size unknown")
                                .monospacedDigit()
                                .foregroundStyle(row.unitPrice == nil ? .secondary : .primary)
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.name).lineLimit(2)
                            Spacer()
                            Text(shelf(row)).monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Today")
            } footer: {
                Text("Shelf price on the right. Unsized eggs count as a dozen and a single banana as 120 g.")
            }
        }
        .navigationTitle(item)
        .navigationBarTitleDisplayMode(.inline)
    }
}
