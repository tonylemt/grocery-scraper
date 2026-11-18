import Foundation
import Observation

struct PriceRow: Codable, Hashable {
    let date: String  // yyyy-MM-dd
    let item: String
    let store: String
    let name: String
    let price: Double
    let unit: String
    let per: String?        // kg, L or dozen
    let unitPrice: Double?  // nil when the package size couldn't be read
    // Where the price came from. Missing on rows collected before Nov 18, 2026.
    let source: String?     // "flyer" (via Flipp) or "online" (store website)
    let url: URL?
    let image: URL?
    let validFrom: String?  // flyer dates, yyyy-MM-dd
    let validTo: String?
    let sale: String?       // flyer sale text, e.g. "SAVE $2"

    var day: Date { Self.dayFormat.date(from: date) ?? .distantPast }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

@MainActor @Observable
final class PriceStore {
    // The file the GitHub Action commits daily. Change this if the repo moves.
    static let dataURL = URL(string: "https://raw.githubusercontent.com/tonylemt/grocery-scraper/main/data/prices.json")!

    var rows: [PriceRow] = []
    var watch: [WatchItem] = []      // watchlist.json from the repo
    var collecting: Set<String> = [] // items added this session, waiting for their first prices
    var error: String?

    private let cache = URL.cachesDirectory.appending(path: "prices.json")
    private let watchCache = URL.cachesDirectory.appending(path: "watchlist.json")

    private static func decode(_ data: Data) throws -> [PriceRow] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([PriceRow].self, from: data)
    }

    init() {
        // Last download, so the app works offline.
        if let data = try? Data(contentsOf: cache) {
            rows = (try? Self.decode(data)) ?? []
        }
        if let data = try? Data(contentsOf: watchCache) {
            watch = (try? JSONDecoder().decode([WatchItem].self, from: data)) ?? []
        }
    }

    private func setWatch(_ items: [WatchItem]) {
        watch = items
        try? JSONEncoder().encode(items).write(to: watchCache)
    }

    /// Adds an item to watchlist.json and starts a collection so it gets prices today.
    func add(_ item: WatchItem) async throws {
        guard Keychain.token != nil else { throw AppError(message: "Add a GitHub token in Settings first.") }
        setWatch(try await GitHub.updateWatchlist(message: "Track \(item.item) (added in the app)") { list in
            guard !list.contains(where: { $0.item.caseInsensitiveCompare(item.item) == .orderedSame }) else {
                throw AppError(message: "You already track \(item.item).")
            }
            return list + [item]
        })
        collecting.insert(item.item)
        do {
            try await GitHub.startCollection()
        } catch {
            collecting.remove(item.item)
            throw AppError(message: "\(item.item) was added, but the collection didn't start (\(error.localizedDescription)). It will get prices in tomorrow's run.")
        }
    }

    /// Removes an item from watchlist.json. Its price history stays in the data.
    func remove(_ name: String) async throws {
        guard Keychain.token != nil else { throw AppError(message: "Add a GitHub token in Settings first.") }
        setWatch(try await GitHub.updateWatchlist(message: "Stop tracking \(name) (removed in the app)") { list in
            list.filter { $0.item != name }
        })
        collecting.remove(name)
    }

    func refresh() async {
        // The watchlist is a separate request; if it fails, the cached copy stays.
        async let latestWatch = try? GitHub.loadWatchlist().items
        await refreshPrices()
        if let items = await latestWatch { setWatch(items) }
    }

    private func refreshPrices() async {
        do {
            var request = URLRequest(url: Self.dataURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            rows = try Self.decode(data)
            try? data.write(to: cache)
            error = nil
        } catch {
            self.error = rows.isEmpty ? "Couldn't load prices. Pull down to retry." : "Couldn't update. Showing saved prices."
        }
    }

    /// Watchlist items in watchlist order. Until the watchlist has loaded once, the items in the data.
    var items: [String] {
        if !watch.isEmpty { return watch.map(\.item) }
        var seen = Set<String>()
        return rows.map(\.item).filter { seen.insert($0).inserted }
    }

    func hasAnyPrices(_ item: String) -> Bool { rows.contains { $0.item == item } }

    var latestDate: String? { rows.map(\.date).max() }

    /// Matches for an item on the most recent collection day: cheapest per unit first,
    /// then products whose size is unknown, by shelf price.
    func current(_ item: String) -> [PriceRow] {
        func key(_ r: PriceRow) -> (Int, Double, Double) { (r.unitPrice == nil ? 1 : 0, r.unitPrice ?? 0, r.price) }
        return rows.filter { $0.item == item && $0.date == latestDate }.sorted { key($0) < key($1) }
    }

    /// Every day this exact product was seen at this store, oldest first.
    func productHistory(_ row: PriceRow) -> [PriceRow] {
        rows.filter { $0.item == row.item && $0.store == row.store && $0.name == row.name }
            .sorted { $0.date < $1.date }
    }

    /// Cheapest unit price per store per day. Products without a unit price are left out.
    func history(_ item: String) -> [PriceRow] {
        var best: [String: PriceRow] = [:]
        for row in rows where row.item == item {
            guard let up = row.unitPrice else { continue }
            let key = row.store + row.date
            if best[key].map({ up < $0.unitPrice! }) ?? true { best[key] = row }
        }
        return best.values.sorted { ($0.store, $0.date) < ($1.store, $1.date) }
    }
}
