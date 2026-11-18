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

/// "$10.76/kg" ("$3.49 each" for shelf-price items), or nil when the size is unknown.
private func perUnit(_ row: PriceRow, lb: Bool) -> String? {
    unitValue(row, lb: lb).map { $0.per == "each" ? "\(cad($0.value)) each" : "\(cad($0.value))/\($0.per)" }
}

private func shortDate(_ day: String) -> String {
    (PriceRow.dayFormat.date(from: day) ?? .distantPast).formatted(.dateTime.month(.abbreviated).day())
}

struct ContentView: View {
    @State private var store = PriceStore()
    @AppStorage("useLb") private var lb = false
    @State private var showSettings = false
    @State private var showAdd = false
    @State private var confirmRemove: String?

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
                                Text(store.collecting.contains(item) ? "Collecting… check back in a few minutes"
                                     : store.hasAnyPrices(item) ? "no price today" : "waiting for first collection")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            }
                        }
                    }
                }
                .onDelete { offsets in confirmRemove = offsets.first.map { store.items[$0] } }
            }
            .confirmationDialog("Stop tracking \(confirmRemove ?? "")?", isPresented: Binding(
                get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
            ), titleVisibility: .visible, presenting: confirmRemove) { name in
                Button("Stop tracking", role: .destructive) {
                    Task {
                        do { try await store.remove(name) } catch { store.error = error.localizedDescription }
                    }
                }
            } message: { _ in
                Text("Its price history is kept. Adding it again with the same name brings the history back.")
            }
            .overlay {
                if store.rows.isEmpty && store.error == nil { ProgressView() }
            }
            .navigationTitle("Grocery Prices")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Weight unit", selection: $lb) {
                        Text("kg").tag(false)
                        Text("lb").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add item", systemImage: "plus") {
                        if Keychain.token == nil { showSettings = true } else { showAdd = true }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAdd) {
                ItemForm(existing: store.items) { try await store.add($0) }
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
    @State private var editing: WatchItem?
    @State private var excluding: PriceRow?

    var body: some View {
        let history = store.history(item)
        let current = store.current(item)
        let sample = current.first(where: { $0.per != nil }) ?? history.first
        let per = sample.flatMap { unitValue($0, lb: lb)?.per } ?? "unit"
        List {
            Section(per == "each" ? "Cheapest by store" : "Cheapest per \(per), by store") {
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
                    .swipeActions {
                        Button("Exclude", systemImage: "eye.slash") { excluding = row }.tint(.red)
                    }
                }
            } header: {
                Text("Today")
            } footer: {
                Text("Shelf price on the right. Tap a product to see where its price comes from, or swipe left to exclude a wrong one. Unsized eggs count as a dozen and a single banana as 120 g.")
            }
        }
        .navigationTitle(item)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let entry = store.watch.first(where: { $0.item == item }) {
                Button("Edit") { editing = entry }
            }
        }
        .sheet(item: $editing) { entry in
            ItemForm(editing: entry, existing: store.items) { try await store.update($0) }
        }
        .modifier(ExcludeDialog(row: $excluding, store: store))
    }
}

/// One product at one store: where the price comes from and its own price history.
struct ProductDetail: View {
    let row: PriceRow
    let store: PriceStore
    @AppStorage("useLb") private var lb = false
    @Environment(\.dismiss) private var dismiss
    @State private var excluding: PriceRow?

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
            Section {
                Button("Not \(row.item)? Exclude this product", systemImage: "eye.slash", role: .destructive) {
                    excluding = row
                }
            }
        }
        .navigationTitle(row.store)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ExcludeDialog(row: $excluding, store: store) { dismiss() })
    }
}

/// Confirms and excludes a wrong product from its item.
private struct ExcludeDialog: ViewModifier {
    @Binding var row: PriceRow?
    let store: PriceStore
    var onDone: () -> Void = {}
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Exclude this product?", isPresented: Binding(
                get: { row != nil }, set: { if !$0 { row = nil } }
            ), titleVisibility: .visible, presenting: row) { r in
                Button("Exclude from \(r.item)", role: .destructive) {
                    Task {
                        do { try await store.exclude(r); onDone() } catch { self.error = error.localizedDescription }
                    }
                }
            } message: { r in
                Text("“\(r.name)” will be hidden from \(r.item), past days included, and won't be collected again. To undo, remove it from Exclude in Edit.")
            }
            .alert("Couldn't exclude", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(error ?? "")
            }
    }
}
