import Charts
import SwiftUI

private let kgPerLb = 0.45359237

private func cad(_ value: Double) -> String { value.formatted(.currency(code: "CAD")) }

/// Shelf price as advertised, e.g. "$4.88 /lb".
private func shelf(_ row: PriceRow) -> String {
    cad(row.price) + (row.unit.isEmpty ? "" : " \(row.unit)")
}

/// Unit price in the viewer's weight unit: per-kg prices become per-lb when `lb` is on.
private func unitValue(_ row: PriceRow, lb: Bool) -> (value: Double, per: String)? {
    guard let up = row.unitPrice, let per = row.per else { return nil }
    return per == "kg" && lb ? (up * kgPerLb, "lb") : (up, per)
}

/// "$10.76/kg", or nil when the size is unknown.
private func perUnit(_ row: PriceRow, lb: Bool) -> String? {
    unitValue(row, lb: lb).map { "\(cad($0.value))/\($0.per)" }
}

private func shortDate(_ day: String) -> String {
    (PriceRow.dayFormat.date(from: day) ?? .distantPast).formatted(.dateTime.month(.abbreviated).day())
}

struct ContentView: View {
    @State private var store = PriceStore()
    @AppStorage("useLb") private var lb = false

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
                                    Text(perUnit(best, lb: lb) ?? shelf(best)).monospacedDigit()
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
            .toolbar {
                Picker("Weight unit", selection: $lb) {
                    Text("kg").tag(false)
                    Text("lb").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .navigationDestination(for: String.self) { ItemDetail(item: $0, store: store) }
            .navigationDestination(for: PriceRow.self) { ProductDetail(row: $0, store: store) }
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
    @AppStorage("useLb") private var lb = false

    var body: some View {
        let history = store.history(item)
        let current = store.current(item)
        let sample = current.first(where: { $0.per != nil }) ?? history.first
        let per = sample.flatMap { unitValue($0, lb: lb)?.per } ?? "unit"
        List {
            Section("Cheapest per \(per), by store") {
                if history.isEmpty {
                    Text("No product sizes could be read yet.").foregroundStyle(.secondary)
                } else {
                    Chart(history, id: \.self) { row in
                        let y = unitValue(row, lb: lb)!.value
                        LineMark(x: .value("Day", row.day, unit: .day), y: .value("Price per \(per)", y))
                            .foregroundStyle(by: .value("Store", row.store))
                        PointMark(x: .value("Day", row.day, unit: .day), y: .value("Price per \(per)", y))
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
                    NavigationLink(value: row) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.store).font(.headline)
                                Spacer()
                                Text(perUnit(row, lb: lb) ?? "size unknown")
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
                }
            } header: {
                Text("Today")
            } footer: {
                Text("Shelf price on the right. Tap a product to see where its price comes from. Unsized eggs count as a dozen and a single banana as 120 g.")
            }
        }
        .navigationTitle(item)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One product at one store: where the price comes from and its own price history.
struct ProductDetail: View {
    let row: PriceRow
    let store: PriceStore
    @AppStorage("useLb") private var lb = false

    var body: some View {
        let history = store.productHistory(row)
        List {
            Section {
                if let image = row.image {
                    AsyncImage(url: image) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                        .frame(maxWidth: .infinity, maxHeight: 220)
                }
                Text(row.name).font(.headline)
                LabeledContent("Store", value: row.store)
                LabeledContent("Shelf price", value: shelf(row))
                LabeledContent("Unit price", value: perUnit(row, lb: lb) ?? "Size unknown")
                if let sale = row.sale, !sale.isEmpty {
                    LabeledContent("Flyer deal", value: sale)
                }
            }
            Section {
                switch row.source {
                case "flyer":
                    LabeledContent("Source", value: "\(row.store) weekly flyer")
                    if let from = row.validFrom, let to = row.validTo {
                        LabeledContent("Flyer valid", value: "\(shortDate(from)) – \(shortDate(to))")
                    }
                case "online":
                    LabeledContent("Source", value: "\(row.store) website price")
                default:
                    LabeledContent("Source", value: row.store == "Walmart" ? "Walmart website price" : "\(row.store) weekly flyer")
                }
                LabeledContent("Collected", value: shortDate(row.date))
                if let url = row.url {
                    Link(destination: url) {
                        Label(row.source == "online" ? "Open on \(row.store) website" : "Open flyer item on Flipp",
                              systemImage: "arrow.up.right.square")
                    }
                }
            } header: {
                Text("Where this price comes from")
            } footer: {
                Text(row.url == nil
                     ? "Collected before links were saved; newer days include a link."
                     : "Prices come from Flipp's search for your postal code, which covers store flyers and Walmart's online prices.")
            }
            Section("Price history for this product") {
                ForEach(history.reversed(), id: \.self) { day in
                    HStack {
                        Text(shortDate(day.date))
                        Spacer()
                        Text(shelf(day)).monospacedDigit().foregroundStyle(.secondary)
                        Text(perUnit(day, lb: lb) ?? "–").monospacedDigit().frame(minWidth: 90, alignment: .trailing)
                    }
                }
            }
        }
        .navigationTitle(row.store)
        .navigationBarTitleDisplayMode(.inline)
    }
}
