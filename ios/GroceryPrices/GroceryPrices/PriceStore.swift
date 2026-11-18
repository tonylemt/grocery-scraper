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
    var error: String?

    private let cache = URL.cachesDirectory.appending(path: "prices.json")

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
    }

    func refresh() async {
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

    /// Watchlist items in the order they first appear in the data.
    var items: [String] {
        var seen = Set<String>()
        return rows.map(\.item).filter { seen.insert($0).inserted }
    }

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
