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
        try needToken()
        setWatch(try await GitHub.updateWatchlist(message: "Track \(item.item) (added in the app)") { list in
            guard !list.contains(where: { $0.item.caseInsensitiveCompare(item.item) == .orderedSame }) else {
                throw AppError(message: "You already track \(item.item).")
            }
            return list + [item]
        })
        try await collect(item.item, saved: "added")
    }

    /// Replaces the item with the same name and re-collects today. The collector recalculates
    /// unit prices for past days too, so a unit change applies to the whole history.
    func update(_ item: WatchItem) async throws {
        try needToken()
        setWatch(try await GitHub.updateWatchlist(message: "Change \(item.item) (edited in the app)") { list in
            list.map { $0.item == item.item ? item : $0 }
        })
        try await collect(item.item, saved: "saved")
    }

    /// Leaves this exact product out of its item: hidden in the app right away (past days too,
    /// the rows stay in the data) and skipped by the collector from the next run.
    func exclude(_ row: PriceRow) async throws {
        try needToken()
        // ponytail: commas become "." (any character) so the edit form keeps the name as one phrase
        let phrase = WatchItem.escape(row.name).replacingOccurrences(of: ",", with: ".")
        setWatch(try await GitHub.updateWatchlist(message: "Exclude \(row.name) from \(row.item)") { list in
            list.map { entry in
                guard entry.item == row.item else { return entry }
                var entry = entry
                entry.exclude = (entry.exclude ?? "").isEmpty ? phrase : entry.exclude! + "|" + phrase
                return entry
            }
        })
    }

    private func needToken() throws {
        guard Keychain.token != nil else { throw AppError(message: "Add a GitHub token in Settings first.") }
    }

    private func collect(_ name: String, saved: String) async throws {
        collecting.insert(name)
        do {
            try await GitHub.startCollection()
        } catch {
            collecting.remove(name)
            throw AppError(message: "\(name) was \(saved), but the collection didn't start (\(error.localizedDescription)). Tomorrow's run will pick it up.")
        }
    }

    /// Removes an item from watchlist.json. Its price history stays in the data.
    func remove(_ name: String) async throws {
        try needToken()
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

    /// An item's rows, minus products its current words leave out (they stay in the data).
    // ponytail: runs the regex over the item's rows on every render; cache per item if it gets slow.
    private func rows(of item: String) -> [PriceRow] {
        let entry = watch.first { $0.item == item }
        return rows.filter { $0.item == item && entry?.matches($0.name) != false }
    }

    func hasAnyPrices(_ item: String) -> Bool { !rows(of: item).isEmpty }

    var latestDate: String? { rows.map(\.date).max() }

    /// Matches for an item on the most recent collection day: cheapest per unit first,
    /// then products whose size is unknown, by shelf price.
    func current(_ item: String) -> [PriceRow] {
        func key(_ r: PriceRow) -> (Int, Double, Double) { (r.unitPrice == nil ? 1 : 0, r.unitPrice ?? 0, r.price) }
        return rows(of: item).filter { $0.date == latestDate }.sorted { key($0) < key($1) }
    }

    /// Every day this exact product was seen at this store, oldest first.
    func productHistory(_ row: PriceRow) -> [PriceRow] {
        rows(of: row.item).filter { $0.store == row.store && $0.name == row.name }
            .sorted { $0.date < $1.date }
    }

    /// Cheapest unit price per store per day. Products without a unit price are left out.
    func history(_ item: String) -> [PriceRow] {
        var best: [String: PriceRow] = [:]
        for row in rows(of: item) {
            guard let up = row.unitPrice else { continue }
            let key = row.store + row.date
            if best[key].map({ up < $0.unitPrice! }) ?? true { best[key] = row }
        }
        return best.values.sorted { ($0.store, $0.date) < ($1.store, $1.date) }
    }

    /// Cheapest unit price across all stores, one row per day, oldest first.
    func dailyBest(_ item: String) -> [PriceRow] {
        var best: [String: PriceRow] = [:]
        for row in history(item) where best[row.date].map({ row.unitPrice! < $0.unitPrice! }) ?? true {
            best[row.date] = row
        }
        return best.values.sorted { $0.date < $1.date }
    }

    /// Every store in the data, alphabetical, so each keeps one colour everywhere.
    var stores: [String] { Set(rows.map(\.store)).sorted() }

    // MARK: Folders and order

    /// The home list: unfiled items, then each folder with its items.
    var homeRows: [Arrange.Row] { watch.isEmpty ? items.map { .item($0) } : Arrange.rows(watch) }

    var folders: [String] { homeRows.compactMap { if case .folder(let f) = $0 { f } else { nil } } }

    /// Saves the order and folders from the home list. Shows them right away and puts the
    /// old ones back if GitHub refuses.
    func arrange(_ rows: [Arrange.Row]) async {
        let placements = Arrange.placements(rows)
        let before = watch
        setWatch(Arrange.arranged(watch, placements))
        do {
            try needToken()
            setWatch(try await GitHub.updateWatchlist(message: "Rearrange items (in the app)") {
                Arrange.arranged($0, placements)
            })
        } catch {
            setWatch(before)
            self.error = "Couldn't save the new order. \(error.localizedDescription)"
        }
    }

    /// Moves an item into a folder (nil: out of any folder). It goes last in its new place,
    /// so a new folder shows up at the bottom.
    func setFolder(_ item: String, _ folder: String?) async throws {
        try needToken()
        let message = folder.map { "Move \(item) to \($0)" } ?? "Take \(item) out of its folder"
        setWatch(try await GitHub.updateWatchlist(message: message + " (in the app)") { list in
            // Grouped first, so taking an item out doesn't reorder the other folders.
            var grouped = Arrange.arranged(list, Arrange.placements(Arrange.rows(list)))
            guard let i = grouped.firstIndex(where: { $0.item == item }) else { return list }
            var entry = grouped.remove(at: i)
            entry.folder = folder
            return grouped + [entry]
        })
    }

    /// Renames a folder. With nil, removes it and leaves its items unfiled.
    func renameFolder(_ old: String, to new: String?) async throws {
        try needToken()
        let message = new.map { "Rename folder \(old) to \($0)" } ?? "Remove folder \(old)"
        setWatch(try await GitHub.updateWatchlist(message: message + " (in the app)") { list in
            list.map { entry in
                var entry = entry
                if entry.folder == old { entry.folder = new }
                return entry
            }
        })
    }
}

/// Home-list order and folders. watchlist.json order is the display order; items with a
/// `folder` sit under that folder's header, and folders show in the order they first appear.
enum Arrange {
    enum Row: Hashable {
        case folder(String), item(String)
        var isFolder: Bool { if case .folder = self { true } else { false } }
    }

    struct Placement: Equatable { let item: String; let folder: String? }

    /// Unfiled items first, then each folder header followed by its items.
    static func rows(_ watch: [WatchItem]) -> [Row] {
        var top: [Row] = [], folders: [String] = [], members: [String: [Row]] = [:]
        for entry in watch {
            guard let f = entry.folder else { top.append(.item(entry.item)); continue }
            if members[f] == nil { folders.append(f) }
            members[f, default: []].append(.item(entry.item))
        }
        return top + folders.flatMap { [.folder($0)] + members[$0]! }
    }

    /// Items in order, each in the folder whose header is nearest above it.
    static func placements(_ rows: [Row]) -> [Placement] {
        var folder: String?
        return rows.compactMap { row in
            switch row {
            case .folder(let f): folder = f; return nil
            case .item(let i): return Placement(item: i, folder: folder)
            }
        }
    }

    /// A list move where a dragged folder header brings its items, and lands between folders
    /// (never inside one, never above unfiled items).
    static func move(_ rows: [Row], from source: IndexSet, to destination: Int) -> [Row] {
        var moving = source, destination = destination
        for i in source where rows[i].isFolder {
            var j = i + 1
            while j < rows.count, !rows[j].isFolder { moving.insert(j); j += 1 }
            let gaps = (0...rows.count).filter { $0 == rows.count || rows[$0].isFolder }
            destination = gaps.min { abs($0 - destination) < abs($1 - destination) }!
        }
        var rest = rows.indices.filter { !moving.contains($0) }.map { rows[$0] }
        rest.insert(contentsOf: moving.map { rows[$0] }, at: destination - moving.count { $0 < destination })
        return rest
    }

    /// The latest watchlist put in this order and these folders. Items not placed (added
    /// elsewhere meanwhile) stay at the end with their own folder; removed ones stay removed.
    static func arranged(_ latest: [WatchItem], _ placements: [Placement]) -> [WatchItem] {
        let byName = Dictionary(latest.map { ($0.item, $0) }, uniquingKeysWith: { a, _ in a })
        let placed = placements.compactMap { p -> WatchItem? in
            guard var entry = byName[p.item] else { return nil }
            entry.folder = p.folder
            return entry
        }
        let names = Set(placements.map(\.item))
        return placed + latest.filter { !names.contains($0.item) }
    }

    #if DEBUG
    static func selfcheck() {
        func w(_ item: String, _ folder: String? = nil) -> WatchItem {
            WatchItem(item: item, query: item, match: item, folder: folder)
        }
        let watch = [w("Milk", "Dairy"), w("Bananas"), w("Beef", "Meat"), w("Eggs", "Dairy")]
        let rows = rows(watch)
        assert(rows == [.item("Bananas"), .folder("Dairy"), .item("Milk"), .item("Eggs"), .folder("Meat"), .item("Beef")])
        // An item dragged to the top leaves its folder.
        let p = placements(move(rows, from: [3], to: 0))
        assert(p.map(\.item) == ["Eggs", "Bananas", "Milk", "Beef"] && p[0].folder == nil && p[2].folder == "Dairy")
        // An item dragged under another header joins that folder.
        assert(placements(move(rows, from: [0], to: 6)).last == Placement(item: "Bananas", folder: "Meat"))
        // A folder brings its items, and snaps to the nearest gap between folders.
        let meatFirst: [Row] = [.item("Bananas"), .folder("Meat"), .item("Beef"), .folder("Dairy"), .item("Milk"), .item("Eggs")]
        assert(move(rows, from: [4], to: 0) == meatFirst)
        assert(move(rows, from: [4], to: 2) == meatFirst)
        assert(move(meatFirst, from: [1], to: 6) == rows)
        // Saving keeps items added elsewhere and drops removed ones.
        let latest = watch.filter { $0.item != "Beef" } + [w("Grapes")]
        let out = arranged(latest, placements(rows))
        assert(out.map(\.item) == ["Bananas", "Milk", "Eggs", "Grapes"] && out[1].folder == "Dairy" && out[3].folder == nil)
    }
    #endif
}
