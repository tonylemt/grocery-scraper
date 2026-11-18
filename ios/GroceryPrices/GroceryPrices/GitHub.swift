import Foundation
import Security

/// One entry of watchlist.json (same fields the collector reads).
struct WatchItem: Codable, Hashable, Identifiable {
    var id: String { item }  // names are unique in the watchlist
    var item: String       // name shown in the app
    var query: String      // search term sent to Flipp
    var per: String?       // kg, L, dozen or each
    var assume: Double?    // typical size for unsized products, in `per` units
    var match: String      // regex the product name must match
    var exclude: String?   // regex that drops a product

    /// Same rule as `matches()` in collector/collect.py.
    func matches(_ name: String) -> Bool {
        guard name.range(of: match, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        if let exclude, !exclude.isEmpty,
           name.range(of: exclude, options: [.regularExpression, .caseInsensitive]) != nil {
            return false
        }
        return true
    }

    private static let special = Set("\\^$.|?*+()[]{}")

    /// Text -> regex that matches it literally.
    static func escape(_ text: String) -> String {
        text.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    /// "greek yogurt, skyr" -> "greek yogurt|skyr", with regex characters escaped. Phrases found in
    /// `sources` (shown text -> regex part, from `phrases(of:)`) keep their original regex. nil when empty.
    static func pattern(fromPhrases text: String, keeping sources: [String: String] = [:]) -> String? {
        let phrases = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !phrases.isEmpty else { return nil }
        return phrases.map { sources[$0] ?? escape($0) }.joined(separator: "|")
    }

    /// Regex -> phrases for the edit form. Plain parts are shown unescaped; parts that use regex
    /// syntax, like `\beggs\b`, are shown as written and saved back unchanged.
    // ponytail: a regex part containing a comma would be split on save; none do today.
    static func phrases(of regex: String?) -> [(shown: String, source: String)] {
        guard let regex, !regex.isEmpty else { return [] }
        var parts: [String] = [], part = "", depth = 0, escaped = false
        for c in regex {  // split on top-level |, not inside (...) or [...]
            if escaped { escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "(" || c == "[" { depth += 1 }
            else if c == ")" || c == "]" { depth -= 1 }
            else if c == "|" && depth == 0 { parts.append(part); part = ""; continue }
            part.append(c)
        }
        parts.append(part)
        return parts.map { (plain($0) ?? $0, $0) }
    }

    /// The literal text of a regex part, or nil when it uses regex syntax.
    private static func plain(_ part: String) -> String? {
        var out = "", escaped = false
        for c in part {
            if escaped {
                guard special.contains(c) else { return nil }
                out.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if special.contains(c) {
                return nil
            } else {
                out.append(c)
            }
        }
        return escaped ? nil : out
    }
}

struct AppError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Reads and writes watchlist.json in the repo, and starts the collector.
enum GitHub {
    static let repo = URL(string: "https://api.github.com/repos/tonylemt/grocery-scraper")!
    private static let path = "contents/watchlist.json"

    private static func call(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: repo.appending(path: path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = Keychain.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func failure(_ data: Data, _ status: Int) -> AppError {
        switch status {
        case 401:
            return AppError(message: "GitHub rejected the token. Check it in Settings.")
        case 403, 404:
            return AppError(message: "The token can't change this repo. It needs Contents and Actions read and write access to grocery-scraper.")
        default:
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            return AppError(message: "GitHub error \(status)" + (detail.map { ": \($0)" } ?? ""))
        }
    }

    private struct File: Decodable { let content: String; let sha: String }

    /// Uses the Contents API rather than raw.githubusercontent.com, which caches for ~5 minutes.
    static func loadWatchlist() async throws -> (items: [WatchItem], sha: String) {
        let (data, status) = try await call(path)
        guard status == 200 else { throw failure(data, status) }
        let file = try JSONDecoder().decode(File.self, from: data)
        guard let json = Data(base64Encoded: file.content, options: .ignoreUnknownCharacters) else {
            throw AppError(message: "Couldn't read watchlist.json from GitHub.")
        }
        return (try JSONDecoder().decode([WatchItem].self, from: json), file.sha)
    }

    /// Applies `change` to the latest watchlist and commits it. If the file changed in
    /// between (409), reloads and tries once more so the other change isn't lost.
    static func updateWatchlist(message: String, _ change: ([WatchItem]) throws -> [WatchItem]) async throws -> [WatchItem] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for attempt in 1...2 {
            let (items, sha) = try await loadWatchlist()
            let updated = try change(items)
            var json = try encoder.encode(updated)
            json.append(0x0A)  // trailing newline
            let body = try JSONSerialization.data(withJSONObject: [
                "message": message, "content": json.base64EncodedString(), "sha": sha,
            ])
            let (data, status) = try await call(path, method: "PUT", body: body)
            if status == 200 || status == 201 { return updated }
            if status == 409 && attempt == 1 { continue }
            throw failure(data, status)
        }
        throw AppError(message: "watchlist.json kept changing on GitHub. Try again.")
    }

    /// Runs the collector now instead of waiting for tomorrow's scheduled run.
    static func startCollection() async throws {
        let (data, status) = try await call("actions/workflows/collect.yml/dispatches", method: "POST",
                                            body: Data(#"{"ref":"main"}"#.utf8))
        guard status == 204 else { throw failure(data, status) }
    }
}

/// The GitHub token, kept in this phone's Keychain.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "github-token",
    ]

    static var token: String? {
        get {
            var query = base
            query[kSecReturnData as String] = true
            var out: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(base as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            var item = base
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

/// A product returned by Flipp, for the add-item preview.
struct FlippHit: Identifiable {
    let id = UUID()
    let store: String
    let name: String
    let price: Double
    let unit: String
}

/// Live Flipp search from the phone, so a new item's words can be tuned before saving.
enum FlippSearch {
    /// Keep in sync with STORES in collector/collect.py.
    static let stores: [(prefix: String, name: String)] = [
        ("freshco", "FreshCo"), ("t&t", "T&T"), ("real canadian superstore", "Superstore"),
        ("walmart", "Walmart"), ("metro", "Metro"), ("farm boy", "Farm Boy"),
    ]

    private struct Response: Decodable { let items: [Hit]?; let ecomItems: [Hit]? }
    private struct Hit: Decodable {
        let name: String?
        let currentPrice: Double?
        let merchantName: String?
        let merchant: String?
        let postPriceText: String?
        let validFrom: String?
    }

    static func search(_ query: String, postal: String) async throws -> [FlippHit] {
        var url = URLComponents(string: "https://backflipp.wishabi.com/flipp/items/search")!
        url.queryItems = [
            URLQueryItem(name: "locale", value: "en-ca"),
            URLQueryItem(name: "postal_code", value: postal.replacingOccurrences(of: " ", with: "")),
            URLQueryItem(name: "q", value: query),
        ]
        let (data, _) = try await URLSession.shared.data(from: url.url!)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        let iso = ISO8601DateFormatter()
        return ((response.items ?? []) + (response.ecomItems ?? [])).compactMap { hit in
            let merchant = (hit.merchantName ?? hit.merchant ?? "").lowercased()
            guard let store = stores.first(where: { merchant.hasPrefix($0.prefix) })?.name,
                  let price = hit.currentPrice, price > 0,
                  let name = hit.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
            if let start = hit.validFrom.flatMap(iso.date(from:)), start > .now { return nil }  // next week's flyer
            return FlippHit(store: store, name: name, price: price, unit: hit.postPriceText ?? "")
        }
    }
}
