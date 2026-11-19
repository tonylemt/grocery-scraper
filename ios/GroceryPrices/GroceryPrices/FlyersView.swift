import SwiftUI

/// A store flyer near the postal code.
struct Flyer: Decodable, Identifiable, Hashable {
    let id: Int
    let merchant: String
    let name: String
    let validFrom: String
    let validTo: String
    let thumbnailUrl: String?
    let categories: [String]?

    var store: String { FlippSearch.shortName(merchant) ?? merchant }

    /// "Nov 19 – Nov 25", "Nov 19 – Nov 25 · ends today" or "Starts Nov 26".
    var dates: String {
        let from = localDay(validFrom) ?? "", to = localDay(validTo) ?? ""
        let today = PriceRow.dayFormat.string(from: .now)
        if from > today { return "Starts " + shortDate(from) }
        return "\(shortDate(from)) – \(shortDate(to))" + (to == today ? " · ends today" : "")
    }
}

/// One product in a flyer.
struct Deal: Identifiable, Hashable {
    let id: Int
    let name: String
    let price: Double?  // nil for multi-buy deals like "2 for $5"
    let discount: Int?
    let image: URL?
    let endsOn: String?

    func listItem(store: String) -> ListItem {
        ListItem(id: id, name: name, store: store, price: price, image: image, endsOn: endsOn)
    }
}

/// Flipp serves images over http, which iOS won't load; the same paths work over https.
private func https(_ url: String?) -> URL? {
    url.flatMap { URL(string: $0.hasPrefix("http://") ? "https://" + $0.dropFirst(7) : $0) }
}

/// Flipp's timestamp as a local day, like local_day() in collector/collect.py.
func localDay(_ iso: String?) -> String? {
    iso.flatMap { ISO8601DateFormatter().date(from: $0) }.map { PriceRow.dayFormat.string(from: $0) }
}

/// Whole flyers from Flipp, fetched live from the phone like the add-item preview.
enum Flyers {
    private static let base = "https://backflipp.wishabi.com/flipp/flyers"

    private static func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// Grocery flyers near a postal code.
    static func list(postal: String) async throws -> [Flyer] {
        var url = URLComponents(string: base)!
        url.queryItems = [
            URLQueryItem(name: "locale", value: "en-ca"),
            URLQueryItem(name: "postal_code", value: postal.replacingOccurrences(of: " ", with: "")),
        ]
        struct Response: Decodable { let flyers: [Flyer] }
        let response: Response = try await get(url.url!)
        return response.flyers.filter { $0.categories?.contains("Groceries") == true }
    }

    private struct Response: Decodable { let items: [Item]; let pages: [Page]? }
    private struct Page: Decodable { let left: Double; let right: Double; let page: Int? }
    private struct Item: Decodable {
        let id: Int
        let name: String?
        let price: String?  // "4.99", or "" for multi-buy deals
        let discount: Double?
        let cutoutImageUrl: String?
        let displayType: Int?  // 5 = banner, not a product
        let validTo: String?
        let left: Double?
        let top: Double?
    }

    /// A flyer's products in reading order: page by page, top to bottom, left to right.
    static func deals(_ flyer: Int) async throws -> [Deal] {
        let response: Response = try await get(URL(string: "\(base)/\(flyer)?locale=en-ca")!)
        let pages = response.pages ?? []
        return response.items
            .filter { $0.displayType != 5 && !($0.name ?? "").isEmpty }
            .map { item -> ((Int, Double, Double), Item) in
                let left = item.left ?? 0
                let page = pages.first { left >= $0.left && left < $0.right }?.page ?? .max
                return ((page, -(item.top ?? 0), left), item)  // top is negative going down the page
            }
            .sorted { $0.0 < $1.0 }
            .map { _, item in
                Deal(id: item.id, name: item.name!, price: item.price.flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil },
                     discount: item.discount.map { Int($0) }, image: https(item.cutoutImageUrl), endsOn: localDay(item.validTo))
            }
    }
}

/// The Flyers tab: current flyers from the stores you pick.
struct FlyersView: View {
    @AppStorage("postalCode") private var postal = ""
    @AppStorage("flyerStores") private var picked: String?  // merchants, one per line; nil = the tracked stores
    @State private var flyers: [Flyer] = []
    @State private var error: String?
    @State private var showStores = false
    @State private var showSettings = false

    private var merchants: [String] { Set(flyers.map(\.merchant)).sorted() }

    private var chosen: Set<String> {
        picked.map { Set($0.split(separator: "\n").map(String.init)) }
            ?? Set(merchants.filter { FlippSearch.shortName($0) != nil })
    }

    var body: some View {
        let shown = Dictionary(grouping: flyers.filter { chosen.contains($0.merchant) }, by: \.store)
        NavigationStack {
            List {
                PageHeader(kicker: postal.isEmpty ? "Store flyers" : "Flyers near \(postal.uppercased())", title: "FLYERS")
                    .listRowBackground(Color.paper)
                    .listRowSeparator(.hidden)
                Group {
                    if postal.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Add your postal code to see this week's flyers from stores near you.")
                                .foregroundStyle(Color.inkSoft)
                            Button("Add postal code") { showSettings = true }.buttonStyle(.borderedProminent)
                        }
                    } else if let error {
                        Label(error, systemImage: "wifi.exclamationmark").font(.label(.caption)).foregroundStyle(Color.deal)
                    } else if !flyers.isEmpty && shown.isEmpty {
                        Text("No stores picked. Tap Stores to choose whose flyers to show.").foregroundStyle(Color.inkSoft)
                    }
                }
                .listRowBackground(Color.paper)
                .listRowSeparator(.hidden)
                ForEach(shown.keys.sorted(), id: \.self) { store in
                    Section {
                        ForEach(shown[store]!.sorted { ($0.validFrom, $0.name) < ($1.validFrom, $1.name) }) { flyer in
                            NavigationLink(value: flyer) { FlyerRow(flyer: flyer) }
                                .listRowBackground(Color.paper)
                                .listRowSeparatorTint(.rule)
                        }
                    } header: {
                        Kicker(store)
                    }
                }
            }
            .listStyle(.plain)
            .paper()
            .overlay {
                if flyers.isEmpty && error == nil && !postal.isEmpty { ProgressView() }
            }
            .navigationTitle("Flyers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                Button("Stores", systemImage: "storefront") { showStores = true }.disabled(flyers.isEmpty)
            }
            .navigationDestination(for: Flyer.self) { FlyerDetail(flyer: $0) }
            .sheet(isPresented: $showStores) {
                StorePicker(merchants: merchants, chosen: Binding(
                    get: { chosen }, set: { picked = $0.sorted().joined(separator: "\n") }))
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task(id: postal) { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        guard !postal.isEmpty else { flyers = []; return }
        do {
            flyers = try await Flyers.list(postal: postal)
            error = nil
        } catch {
            if !Task.isCancelled {
                self.error = flyers.isEmpty ? "Couldn't load flyers. Pull down to retry." : "Couldn't update. Showing earlier flyers."
            }
        }
    }
}

private struct FlyerRow: View {
    let flyer: Flyer

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: https(flyer.thumbnailUrl)) { $0.resizable().scaledToFill() } placeholder: { Color.card }
                .frame(width: 56, height: 72)
                .clipShape(.rect(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.rule))
            VStack(alignment: .leading, spacing: 6) {
                Text(flyer.name).font(.name(.headline)).foregroundStyle(Color.ink).lineLimit(2)
                Kicker(flyer.dates)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Which stores' flyers to show, from the grocery chains with flyers nearby.
private struct StorePicker: View {
    let merchants: [String]
    @Binding var chosen: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(merchants, id: \.self) { merchant in
                        Toggle(merchant, isOn: Binding(
                            get: { chosen.contains(merchant) },
                            set: { if $0 { chosen.insert(merchant) } else { chosen.remove(merchant) } }))
                    }
                } footer: {
                    Text("Grocery stores with flyers near your postal code.")
                }
                .listRowBackground(Color.card)
            }
            .paper()
            .navigationTitle("Stores")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// One flyer as a grid of products. Tapping one puts it on the shopping list, or takes it off.
struct FlyerDetail: View {
    let flyer: Flyer
    @Environment(ShoppingList.self) private var list
    @State private var deals: [Deal] = []
    @State private var error: String?
    @State private var query = ""
    @State private var taps = 0

    var body: some View {
        let shown = query.isEmpty ? deals : deals.filter { $0.name.localizedCaseInsensitiveContains(query) }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Kicker("\(flyer.store) · \(flyer.dates)")
                Text(flyer.name).font(.name(.title)).foregroundStyle(Color.ink)
                Kicker("Tap an item to add it to your list")
                if let error {
                    Label(error, systemImage: "wifi.exclamationmark").font(.label(.caption)).foregroundStyle(Color.deal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top])
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(shown) { deal in
                    let on = list.contains(deal.id)
                    Button {
                        list.toggle(deal.listItem(store: flyer.store))
                        taps += 1
                    } label: {
                        DealCard(deal: deal, onList: on)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(on ? "On your list" : "")
                    .contextMenu {
                        Link(destination: URL(string: "https://flipp.com/en-ca/item/\(deal.id)")!) {
                            Label("Open on Flipp", systemImage: "arrow.up.right")
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color.paper)
        .searchable(text: $query, prompt: "Search this flyer")
        .sensoryFeedback(.selection, trigger: taps)
        .overlay {
            if deals.isEmpty && error == nil { ProgressView() }
        }
        .navigationTitle(flyer.store)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .task {
            do { deals = try await Flyers.deals(flyer.id) } catch {
                if !Task.isCancelled { self.error = "Couldn't load this flyer. Go back and try again." }
            }
        }
    }
}

private struct DealCard: View {
    let deal: Deal
    let onList: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: deal.image) { $0.resizable().scaledToFit() } placeholder: { Color.white }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .padding(8)
                .background(.white, in: .rect(cornerRadius: 4))
            Text(deal.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                if let price = deal.price {
                    FlyerPrice(amount: price, size: .title2).foregroundStyle(Color.ink)
                } else {
                    Kicker("Deal in flyer")
                }
                Spacer(minLength: 4)
                if let off = deal.discount, off > 0 { DealBadge(text: "Save \(off)%") }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.card, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(onList ? Color.ink : Color.rule, lineWidth: onList ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if onList {
                Label("On list", systemImage: "checkmark")
                    .font(.label(.caption2)).fontWeight(.bold)
                    .priceTag()
                    .padding(8)
            }
        }
    }
}
