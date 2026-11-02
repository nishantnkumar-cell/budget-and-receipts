import SwiftUI

@main
struct BudgetReceiptsApp: App {
    @StateObject private var store = BudgetStore()
    @StateObject private var subscriptions = SubscriptionStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    @State private var cloud: CloudSync?

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
            // A receipt or statement opened with the app ("Open in", or Open With on the Mac).
            .onOpenURL { url in
                Task { await SharedReceiptReader.open(url, into: store) }
            }
            .task(id: scenePhase) {
                // Receipts shared from other apps while this one was closed.
                if scenePhase == .active { await SharedReceiptReader.readDropped(into: store) }
                if scenePhase == .active { await cloud?.refresh() }
            }
            .task(id: settings.iCloudSyncEnabled) { await startOrStopSync() }
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

    /// iCloud sync runs only when it is switched on, the build has iCloud, and not under tests.
    private func startOrStopSync() async {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard settings.iCloudSyncEnabled, CloudSync.containerID != nil, !testing else {
            cloud = nil
            store.didPersist = nil
            subscriptions.didPersist = nil
            return
        }
        let sync = CloudSync(sources: [store, subscriptions], imagesFolder: store.imagesFolder, stateFolder: JSONFileStorage.defaultFolder)
        cloud = sync
        store.didPersist = { Task { await sync.localDataChanged() } }
        subscriptions.didPersist = { Task { await sync.localDataChanged() } }
        await sync.start()
    }
}
