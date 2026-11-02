import SwiftUI
@main struct BudgetMacPersonalApp: App {
    @StateObject private var store = BudgetStore()
    @StateObject private var subscriptions = SubscriptionStore()
    var body: some Scene {
        WindowGroup { AdaptiveRootView().environmentObject(store).environmentObject(subscriptions) }
    }
}
