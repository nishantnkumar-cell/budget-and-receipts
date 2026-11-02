import SwiftUI

@main
struct BudgetReceiptsApp: App {
    @StateObject private var store = BudgetStore()
    @StateObject private var subscriptions = SubscriptionStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if settings.appLockEnabled && !lock.isUnlocked {
                    LockScreen(lock: lock)
                } else {
                    AdaptiveRootView()
                        // Rebuild every screen when the currency changes so all amounts update.
                        .id(settings.currencyCode)
                }
            }
            .environmentObject(store)
            .environmentObject(subscriptions)
            .environmentObject(settings)
            .task(id: subscriptions.contracts) {
                await ReminderScheduler.reschedule(subscriptions.contracts, enabled: settings.remindersEnabled)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { lock.lock() }
        }
        #if os(macOS)
        .commands { ImportFromDevicesCommands() }
        #endif
    }
}
