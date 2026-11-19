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

func shortDate(_ day: String) -> String {
    (PriceRow.dayFormat.date(from: day) ?? .distantPast).formatted(.dateTime.month(.abbreviated).day())
}

struct ContentView: View {
    let store: PriceStore
    @AppStorage("useLb") private var lb = false
    @AppStorage("collapsedFolders") private var collapsedFolders = ""  // one folder per line
    @State private var showSettings = false
    @State private var showAdd = false
    @State private var confirmRemove: String?
    @State private var editMode = EditMode.inactive
    @State private var draft: [Arrange.Row] = []  // the list while arranging
    @State private var newFolderFor: String?      // item waiting for a new folder's name
    @State private var renaming: String?          // folder being renamed
    @State private var folderName = ""

    private var arranging: Bool { editMode.isEditing }
    private var collapsed: Set<String> { Set(collapsedFolders.split(separator: "\n").map(String.init)) }

    /// The rows on screen: everything while arranging, otherwise minus items in collapsed folders.
    private var rows: [Arrange.Row] {
        if arranging { return draft }
        var folder: String?
        return store.homeRows.filter { row in
            if case .folder(let f) = row { folder = f; return true }
            return folder.map { !collapsed.contains($0) } ?? true
        }
    }

    var body: some View {
        let rows = rows
        let counts = Dictionary(Arrange.placements(arranging ? draft : store.homeRows).compactMap(\.folder).map { ($0, 1) },
                                uniquingKeysWith: +)
        NavigationStack {
            List {
                Masthead(store: store)
                    .listRowBackground(Color.paper)
                    .listRowSeparator(.hidden)
                ForEach(rows, id: \.self) { row in
                    switch row {
                    case .folder(let name):
                        FolderHeader(name: name, count: counts[name] ?? 0,
                                     collapsed: !arranging && collapsed.contains(name)) { toggleCollapsed(name) }
                            .contextMenu { if !arranging { folderMenu(name) } }
                            .deleteDisabled(true)
                            .listRowBackground(Color.paper)
                            .listRowSeparator(.hidden)
                    case .item(let item):
                        NavigationLink(value: item) { ItemRow(item: item, store: store, lb: lb) }
                            .contextMenu { if !arranging { moveMenu(item) } }
                            .listRowBackground(Color.paper)
                            .listRowSeparatorTint(.rule)
                    }
                }
                .onDelete(perform: arranging ? nil : { offsets in
                    if case .item(let item)? = offsets.first.map({ rows[$0] }) { confirmRemove = item }
                })
                .onMove(perform: arranging ? { draft = Arrange.move(draft, from: $0, to: $1) } : nil)
            }
            .listStyle(.plain)
            .paper()
            .environment(\.editMode, $editMode)
            .alert("New folder", isPresented: Binding(
                get: { newFolderFor != nil }, set: { if !$0 { newFolderFor = nil } }
            )) {
                TextField("Name, e.g. Dairy", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Move") { if let item = newFolderFor { setFolder(item, cleaned(folderName)) } }
            } message: {
                Text("Move \(newFolderFor ?? "") into a new folder.")
            }
            .alert("Rename folder", isPresented: Binding(
                get: { renaming != nil }, set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $folderName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let old = renaming, let new = cleaned(folderName), new != old { renameFolder(old, to: new) }
                }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)  // the masthead is the title
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if arranging {
                        Button("Done") { finishArranging() }.fontWeight(.semibold)
                    } else {
                        Button("Arrange", systemImage: "arrow.up.arrow.down") { startArranging() }
                    }
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
        }
    }

    private func startArranging() {
        guard Keychain.token != nil else { showSettings = true; return }
        draft = store.homeRows
        withAnimation { editMode = .active }
    }

    private func finishArranging() {
        withAnimation { editMode = .inactive }
        guard Arrange.placements(draft) != Arrange.placements(store.homeRows) else { return }
        Task { await store.arrange(draft) }
    }

    private func toggleCollapsed(_ folder: String) {
        guard !arranging else { return }
        var set = collapsed
        if !set.insert(folder).inserted { set.remove(folder) }
        withAnimation { collapsedFolders = set.sorted().joined(separator: "\n") }
    }

    /// A typed folder name, trimmed, spelled like an existing folder when it matches one. nil when blank.
    private func cleaned(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return store.folders.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    @ViewBuilder private func moveMenu(_ item: String) -> some View {
        let current = store.watch.first { $0.item == item }?.folder
        Menu("Move to folder", systemImage: "folder") {
            ForEach(store.folders.filter { $0 != current }, id: \.self) { folder in
                Button(folder) { setFolder(item, folder) }
            }
            Button("New folder…", systemImage: "folder.badge.plus") { folderName = ""; newFolderFor = item }
            if current != nil {
                Button("Remove from folder", systemImage: "folder.badge.minus") { setFolder(item, nil) }
            }
        }
    }

    @ViewBuilder private func folderMenu(_ folder: String) -> some View {
        Button("Rename…", systemImage: "pencil") { folderName = folder; renaming = folder }
        Button("Remove folder", systemImage: "folder.badge.minus") { renameFolder(folder, to: nil) }
    }

    private func setFolder(_ item: String, _ folder: String?) {
        guard Keychain.token != nil else { showSettings = true; return }
        Task {
            do { try await store.setFolder(item, folder) } catch { store.error = error.localizedDescription }
        }
    }

    private func renameFolder(_ old: String, to new: String?) {
        guard Keychain.token != nil else { showSettings = true; return }
        Task {
            do { try await store.renameFolder(old, to: new) } catch { store.error = error.localizedDescription }
        }
    }
}

/// A folder on the home list, printed like a flyer's department banner. Tap to fold it away.
private struct FolderHeader: View {
    let name: String
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Text(name.uppercased())
                    .font(.price(.title3))
                    .foregroundStyle(Color.paper)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.ink)
                Kicker(count == 1 ? "1 item" : "\(count) items")
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.ink)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityLabel("\(name), \(count) items")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }
}

/// The flyer's front page: date, headline, and a heavy double rule.
private struct Masthead: View {
    let store: PriceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(kicker: store.latestDate.map {
                "Prices from " + (PriceRow.dayFormat.date(from: $0) ?? .now)
                    .formatted(.dateTime.weekday(.wide).month(.wide).day())
            } ?? "Price watch", title: "BEST PRICES")
            HStack {
                Kicker("\(store.items.count) items")
                Spacer()
                Kicker("\(store.stores.count) stores · cheapest per unit")
            }
            if let error = store.error {
                Label(error, systemImage: "wifi.exclamationmark").font(.label(.caption)).foregroundStyle(Color.deal)
            }
        }
    }
}

/// One item on the front page: name, where it's cheapest, its recent trend, and the price tag.
private struct ItemRow: View {
    let item: String
    let store: PriceStore
    let lb: Bool

    var body: some View {
        let today = store.current(item)
        // ponytail: the last two weeks; make the window a setting if longer trends matter.
        let days = Array(store.dailyBest(item).suffix(14))
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item).font(.name(.title3)).foregroundStyle(Color.ink)
                if let best = today.first {
                    let count = Set(today.map(\.store)).count
                    HStack(spacing: 6) {
                        StoreDot(name: best.store, stores: store.stores)
                        Kicker(count > 1 ? "\(best.store) · best of \(count)" : best.store)
                    }
                    if days.count > 1 {
                        HStack(spacing: 8) {
                            Sparkline(days: days)
                            Trend(days: days)
                        }
                    }
                } else {
                    Text(store.collecting.contains(item) ? "Collecting… check back in a few minutes"
                         : store.hasAnyPrices(item) ? "No price today" : "Waiting for first collection")
                        .font(.label(.caption)).foregroundStyle(Color.inkSoft)
                }
            }
            Spacer(minLength: 8)
            if let best = today.first {
                let v = unitValue(best, lb: lb)
                FlyerPrice(amount: v?.value ?? best.price, per: v?.per).priceTag()
            }
        }
        .padding(.vertical, 10)
    }
}

/// The cheapest price per day as a tiny ink line.
private struct Sparkline: View {
    let days: [PriceRow]

    var body: some View {
        Chart(days, id: \.self) {
            LineMark(x: .value("Day", $0.day, unit: .day), y: .value("Price", $0.unitPrice ?? 0))
                .foregroundStyle(Color.ink)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(width: 64, height: 18)
        .accessibilityHidden(true)  // Trend says it in words
    }
}

/// "↓ 8% since Nov 12", from the first to the last day given.
private struct Trend: View {
    let days: [PriceRow]  // cheapest per day, oldest first

    var body: some View {
        if let first = days.first, let last = days.last, let a = first.unitPrice, let b = last.unitPrice, a > 0 {
            let change = (b - a) / a
            let pct = Int((abs(change) * 100).rounded())
            let since = "since \(shortDate(first.date))"
            Group {
                if pct == 0 {
                    Label("Steady \(since)", systemImage: "equal").foregroundStyle(Color.inkSoft)
                } else {
                    Label("\(pct)% \(since)", systemImage: change < 0 ? "arrow.down" : "arrow.up")
                        .foregroundStyle(change < 0 ? Color.cheaper : Color.pricier)
                        .accessibilityLabel("\(change < 0 ? "Down" : "Up") \(pct)% \(since)")
                }
            }
            .font(.label(.caption2))
            .labelStyle(TightLabel())
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.fontWeight(.bold); configuration.title }
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
            VStack(alignment: .leading, spacing: 12) {
                Kicker(per == "each" ? "Cheapest shelf price today" : "Cheapest per \(per) today")
                Text(item).font(.name(.largeTitle)).foregroundStyle(Color.ink)
                if let best = current.first, let v = unitValue(best, lb: lb) {
                    HStack(spacing: 16) {
                        FlyerPrice(amount: v.value, per: v.per).priceTag()
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                StoreDot(name: best.store, stores: store.stores)
                                Text(best.store).font(.headline).foregroundStyle(Color.ink)
                            }
                            Trend(days: store.dailyBest(item))
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))

            Section {
                if history.isEmpty {
                    Text("No product sizes could be read yet.").foregroundStyle(Color.inkSoft)
                } else {
                    StoreChart(history: history, per: per, lb: lb, stores: store.stores)
                        .padding(.vertical, 8)
                }
            } header: {
                Kicker(per == "each" ? "Cheapest by store" : "Cheapest per \(per), by store")
            } footer: {
                if !history.isEmpty { Text("Touch and drag the chart to compare stores on one day.") }
            }
            .listRowBackground(Color.card)

            Section {
                ForEach(Array(current.enumerated()), id: \.element) { i, row in
                    NavigationLink(value: row) { OfferRow(row: row, rank: i + 1, lb: lb, stores: store.stores) }
                        .swipeActions {
                            Button("Exclude", systemImage: "eye.slash") { excluding = row }.tint(.deal)
                        }
                }
            } header: {
                Kicker("Today, cheapest first")
            } footer: {
                Text("Shelf price under each unit price. Tap a product to see where its price comes from, or swipe left to exclude a wrong one. Unsized eggs count as a dozen and a single banana as 120 g.")
            }
            .listRowBackground(Color.card)
        }
        .paper()
        .navigationTitle(item)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)  // the hero shows the name
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

/// Cheapest unit price per store per day, one coloured line per store. Drag to read one day.
private struct StoreChart: View {
    let history: [PriceRow]
    let per: String
    let lb: Bool
    let stores: [String]
    @State private var picked: Date?

    var body: some View {
        let shown = stores.filter { s in history.contains { $0.store == s } }
        let day = picked.map { d in history.filter { Calendar.current.isDate($0.day, inSameDayAs: d) } } ?? []
        Chart {
            ForEach(history, id: \.self) { row in
                let y = unitValue(row, lb: lb)!.value
                LineMark(x: .value("Day", row.day, unit: .day), y: .value("Price per \(per)", y))
                    .foregroundStyle(by: .value("Store", row.store))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Day", row.day, unit: .day), y: .value("Price per \(per)", y))
                    .foregroundStyle(by: .value("Store", row.store))
                    .symbolSize(36)
            }
            if let first = day.first {
                RuleMark(x: .value("Day", first.day, unit: .day))
                    .foregroundStyle(Color.inkSoft.opacity(0.5))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        DayCallout(rows: day, lb: lb, stores: stores)
                    }
            }
        }
        .chartForegroundStyleScale(domain: shown, range: shown.map { Color.store($0, among: stores) })
        .chartXSelection(value: $picked)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.rule)
                AxisValueLabel().font(.label(.caption2)).foregroundStyle(Color.inkSoft)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.rule)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(cad(v)).font(.label(.caption2)).foregroundStyle(Color.inkSoft) }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: 12)
        .frame(height: 260)
    }
}

/// Every store's price on the day under the finger, cheapest first.
private struct DayCallout: View {
    let rows: [PriceRow]
    let lb: Bool
    let stores: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(shortDate(rows[0].date))
            ForEach(rows.sorted { ($0.unitPrice ?? 0) < ($1.unitPrice ?? 0) }, id: \.self) { r in
                HStack(spacing: 6) {
                    StoreDot(name: r.store, stores: stores)
                    Text(r.store)
                    Spacer(minLength: 8)
                    Text(perUnit(r, lb: lb) ?? "–").monospacedDigit().fontWeight(.semibold)
                }
                .font(.caption)
            }
        }
        .foregroundStyle(Color.ink)
        .padding(8)
        .frame(width: 180)
        .background(Color.card, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.rule))
    }
}

/// One product on today's ranking. The cheapest gets the yellow tag.
private struct OfferRow: View {
    let row: PriceRow
    let rank: Int
    let lb: Bool
    let stores: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", rank)).font(.label(.caption)).foregroundStyle(Color.inkSoft).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StoreDot(name: row.store, stores: stores)
                    Text(row.store).font(.headline).foregroundStyle(Color.ink)
                }
                Text(row.name).font(.caption).foregroundStyle(Color.inkSoft).lineLimit(2)
                if let sale = row.sale, !sale.isEmpty { DealBadge(text: sale) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let v = unitValue(row, lb: lb) {
                    let price = FlyerPrice(amount: v.value, per: v.per, size: .title2)
                    if rank == 1 { price.priceTag() } else { price.foregroundStyle(Color.ink) }
                } else {
                    Kicker("Size unknown")
                }
                Text(shelf(row)).font(.label(.caption2)).foregroundStyle(Color.inkSoft)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One product at one store, printed as a receipt: where the price comes from and its own history.
struct ProductDetail: View {
    let row: PriceRow
    let store: PriceStore
    @AppStorage("useLb") private var lb = false
    @Environment(\.dismiss) private var dismiss
    @State private var excluding: PriceRow?

    private var source: String {
        switch row.source {
        case "flyer": "\(row.store) weekly flyer"
        case "online": "\(row.store) website"
        default: row.store == "Walmart" ? "Walmart website" : "\(row.store) weekly flyer"
        }
    }

    var body: some View {
        let history = store.productHistory(row)
        ScrollView {
            VStack(spacing: 24) {
                receipt(history)
                Button("Not \(row.item)? Exclude this product", systemImage: "eye.slash", role: .destructive) {
                    excluding = row
                }
                .font(.label(.footnote))
                .tint(.deal)
                Text(row.url == nil
                     ? "Collected before links were saved; newer days include a link."
                     : "Prices come from Flipp's search for your postal code, which covers store flyers and Walmart's online prices.")
                    .font(.footnote)
                    .foregroundStyle(Color.inkSoft)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.paper)
        .navigationTitle(row.store)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)  // the receipt header shows the store
        .modifier(ExcludeDialog(row: $excluding, store: store) { dismiss() })
    }

    private func receipt(_ history: [PriceRow]) -> some View {
        VStack(spacing: 14) {
            if let image = row.image {
                AsyncImage(url: image) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(maxWidth: .infinity, maxHeight: 170)
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 4))
            }
            Text("*** \(row.store.uppercased()) ***").font(.label(.footnote)).fontWeight(.bold).tracking(2)
            Text(row.name).font(.name(.title3)).multilineTextAlignment(.center)

            Perforation()
            VStack(spacing: 8) {
                line("Shelf price", shelf(row))
                if let sale = row.sale, !sale.isEmpty {
                    HStack { label("Flyer deal"); Spacer(); DealBadge(text: sale) }
                }
                line("Source", source)
                if let from = row.validFrom, let to = row.validTo {
                    line("Flyer valid", "\(shortDate(from)) – \(shortDate(to))")
                }
                line("Collected", shortDate(row.date))
            }

            Perforation()
            HStack(alignment: .center) {
                Text(unitValue(row, lb: lb).map { $0.per == "each" ? "PRICE" : "PER \($0.per.uppercased())" } ?? "UNIT PRICE")
                    .font(.label(.headline)).fontWeight(.heavy)
                Spacer()
                if let v = unitValue(row, lb: lb) {
                    FlyerPrice(amount: v.value, per: v.per).priceTag()
                } else {
                    Kicker("Size unknown")
                }
            }

            Perforation()
            VStack(spacing: 6) {
                Kicker("Price history")
                ForEach(history.reversed(), id: \.self) { day in
                    HStack {
                        Text(shortDate(day.date).uppercased())
                        Spacer()
                        Text(shelf(day)).foregroundStyle(Color.inkSoft)
                        Text(perUnit(day, lb: lb) ?? "–").frame(minWidth: 96, alignment: .trailing)
                    }
                    .font(.label(.caption))
                }
            }

            if let url = row.url {
                Perforation()
                Link(destination: url) {
                    Label(row.source == "online" ? "Open on \(row.store) website" : "Open flyer item on Flipp",
                          systemImage: "arrow.up.right")
                        .font(.label(.footnote)).fontWeight(.bold)
                }
            }
            Kicker("Thank you for shopping around")
                .padding(.top, 4)
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 20)
        .padding(.vertical, 30)
        .background(ReceiptShape().fill(Color.card).shadow(color: .black.opacity(0.10), radius: 10, y: 4))
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.label(.caption)).foregroundStyle(Color.inkSoft)
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            label(name)
            Spacer(minLength: 12)
            Text(value).font(.label(.caption)).multilineTextAlignment(.trailing)
        }
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
