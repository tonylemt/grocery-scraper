import SwiftUI
import UserNotifications

/// A flyer deal you want to buy.
struct ListItem: Codable, Identifiable, Hashable {
    let id: Int          // Flipp flyer item id
    let name: String
    let store: String
    let price: Double?   // nil for multi-buy deals like "2 for $5"
    let image: URL?
    let endsOn: String?  // the deal's last day, yyyy-MM-dd, local time
    var done = false
}

/// "Ends today", "Ends Nov 25" or "Ended", from a deal's last day.
func dealEnds(_ day: String?) -> String? {
    guard let day else { return nil }
    let today = PriceRow.dayFormat.string(from: .now)
    return day < today ? "Ended" : day == today ? "Ends today" : "Ends " + shortDate(day)
}

/// Deals tapped in a flyer, kept on this phone, with a notification the evening before they end.
@MainActor @Observable
final class ShoppingList {
    private(set) var items: [ListItem] = []
    private let file = URL.documentsDirectory.appending(path: "shopping-list.json")

    init() {
        items = (try? JSONDecoder().decode([ListItem].self, from: Data(contentsOf: file))) ?? []
    }

    var open: Int { items.count { !$0.done } }

    func contains(_ id: Int) -> Bool { items.contains { $0.id == id } }

    func toggle(_ item: ListItem) {
        if contains(item.id) { items.removeAll { $0.id == item.id } } else { items.append(item) }
        save()
    }

    func setDone(_ id: Int, _ done: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done = done
        save()
    }

    func remove(_ ids: [Int]) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clearDone() {
        items.removeAll(where: \.done)
        save()
    }

    private func save() {
        try? JSONEncoder().encode(items).write(to: file)
        Task { await reschedule() }
    }

    /// One notification per end date, for deals not bought yet. Asks permission the first time.
    private func reschedule() async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("deal-end-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        let byDay = Dictionary(grouping: items.filter { !$0.done && $0.endsOn != nil }) { $0.endsOn! }
        guard !byDay.isEmpty, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for (day, deals) in byDay {
            guard let at = Self.notifyAt(endsOn: day, now: .now) else { continue }
            let content = UNMutableNotificationContent()
            content.title = deals.count == 1 ? "A deal on your list ends tomorrow"
                                             : "\(deals.count) deals on your list end tomorrow"
            content.body = deals.map { "\($0.name) at \($0.store)" }.joined(separator: "\n")
            content.sound = .default
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            try? await center.add(UNNotificationRequest(identifier: "deal-end-\(day)", content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false)))
        }    }

    /// 6 pm the day before a deal's last day, or nil once that's passed.
    nonisolated static func notifyAt(endsOn: String, now: Date) -> Date? {
        let calendar = Calendar.current
        guard let last = PriceRow.dayFormat.date(from: endsOn),
              let eve = calendar.date(byAdding: .day, value: -1, to: last),
              let at = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: eve), at > now else { return nil }
        return at
    }

    #if DEBUG
    nonisolated static func selfcheck() {
        let noon = PriceRow.dayFormat.date(from: "2026-11-19")!.addingTimeInterval(12 * 3600)
        let at = Calendar.current.dateComponents([.month, .day, .hour], from: notifyAt(endsOn: "2026-11-25", now: noon)!)
        assert(at.month == 11 && at.day == 24 && at.hour == 18)
        assert(notifyAt(endsOn: "2026-11-20", now: noon) != nil)  // ends tomorrow: tonight at 6
        assert(notifyAt(endsOn: "2026-11-19", now: noon) == nil)  // ends today: too late
    }
    #endif
}

/// The To buy tab: tapped flyer deals, grouped by store.
struct ShoppingListView: View {
    @Environment(ShoppingList.self) private var list

    var body: some View {
        let stores = Dictionary(grouping: list.items, by: \.store)
        NavigationStack {
            List {
                PageHeader(kicker: "\(list.open) to buy · \(stores.count == 1 ? "1 store" : "\(stores.count) stores")",
                           title: "TO BUY")
                    .listRowBackground(Color.paper)
                    .listRowSeparator(.hidden)
                if list.items.isEmpty {
                    Text("Tap items in a flyer to add them here. You'll get a reminder the evening before a deal ends.")
                        .font(.label(.footnote))
                        .foregroundStyle(Color.inkSoft)
                        .listRowBackground(Color.paper)
                        .listRowSeparator(.hidden)
                }
                ForEach(stores.keys.sorted(), id: \.self) { store in
                    let items = stores[store]!
                    Section {
                        ForEach(items) { item in
                            ListRow(item: item) { list.setDone(item.id, !item.done) }
                                .listRowBackground(Color.paper)
                                .listRowSeparatorTint(.rule)
                        }
                        .onDelete { offsets in list.remove(offsets.map { items[$0].id }) }
                    } header: {
                        Kicker(store)
                    }
                }
            }
            .listStyle(.plain)
            .paper()
            .navigationTitle("To buy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                if list.items.contains(where: \.done) {
                    Button("Clear done") { withAnimation { list.clearDone() } }
                }
            }
        }
    }
}

private struct ListRow: View {
    let item: ListItem
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ink)
            .accessibilityLabel(item.done ? "Bought" : "Not bought")
            AsyncImage(url: item.image) { $0.resizable().scaledToFit() } placeholder: { Color.white }
                .frame(width: 52, height: 52)
                .padding(4)
                .background(.white, in: .rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2).strikethrough(item.done)
                if let ends = dealEnds(item.endsOn) {
                    Kicker(ends, color: ends == "Ended" ? .deal : .inkSoft)
                }
            }
            .foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            if let price = item.price {
                FlyerPrice(amount: price, size: .title2).foregroundStyle(Color.ink)
            }
        }
        .opacity(item.done ? 0.5 : 1)
        .padding(.vertical, 4)
    }
}
