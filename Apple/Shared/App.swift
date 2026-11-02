import SwiftUI

@main
struct BudgetReceiptsApp: App {
    @StateObject private var store = BudgetStore()
    @StateObject private var subscriptions = SubscriptionStore()

    var body: some Scene {
        WindowGroup {
            AdaptiveRootView()
                .environmentObject(store)
                .environmentObject(subscriptions)
        }
    }
}
