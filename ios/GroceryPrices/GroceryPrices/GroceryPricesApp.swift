import SwiftUI

@main
struct GroceryPricesApp: App {
    @State private var store = PriceStore()
    @State private var list = ShoppingList()

    init() {
        #if DEBUG
        Arrange.selfcheck()
        ShoppingList.selfcheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Prices", systemImage: "tag") { ContentView(store: store) }
                Tab("Flyers", systemImage: "newspaper") { FlyersView() }
                Tab("To buy", systemImage: "checklist") { ShoppingListView() }
                    .badge(list.open)
            }
            .environment(list)
            .tint(.ink)
        }
    }
}
