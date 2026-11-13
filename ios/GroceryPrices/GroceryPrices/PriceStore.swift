import Foundation
import Observation

struct PriceRow: Codable, Hashable {
    let date: String  // yyyy-MM-dd
    let item: String
    let store: String
    let name: String
    let price: Double
    let unit: String

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

    init() {
        // Last download, so the app works offline.
        if let data = try? Data(contentsOf: cache) {
            rows = (try? JSONDecoder().decode([PriceRow].self, from: data)) ?? []
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
            rows = try JSONDecoder().decode([PriceRow].self, from: data)
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

    /// Matches for an item on the most recent collection day, cheapest first.
    func current(_ item: String) -> [PriceRow] {
        rows.filter { $0.item == item && $0.date == latestDate }.sorted { $0.price < $1.price }
    }

    /// Cheapest matching price per store per day.
    func history(_ item: String) -> [PriceRow] {
        var best: [String: PriceRow] = [:]
        for row in rows where row.item == item {
            let key = row.store + row.date
            if best[key].map({ row.price < $0.price }) ?? true { best[key] = row }
        }
        return best.values.sorted { ($0.store, $0.date) < ($1.store, $1.date) }
    }
}
