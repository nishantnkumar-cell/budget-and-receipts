import SwiftUI

@main
struct BudgetReceiptsApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if DEBUG
    @StateObject private var store = SampleData.isOn ? SampleData.budgetStore() : BudgetStore()
    @StateObject private var subscriptions = SampleData.isOn ? SampleData.subscriptionStore() : SubscriptionStore()
    #else
    @StateObject private var store = BudgetStore()
    @StateObject private var subscriptions = SubscriptionStore()
    #endif
    @StateObject private var settings = AppSettings()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    @State private var cloud: CloudSync?
    @StateObject private var syncStatus = SyncStatus()
    /// When the app last stopped being in front, to lock the Mac after a while away.
    @State private var leftAt: Date?

    var body: some Scene {
        WindowGroup {
            Group {
                if settings.appLockEnabled && !lock.isUnlocked {
                    LockScreen(lock: lock)
                } else if settings.appLockEnabled && scenePhase != .active {
                    // Covers figures in the app switcher and screenshots taken while away.
                    PrivacyCover()
                } else {
                    AdaptiveRootView()
                        // Rebuild every screen when the currency changes so all amounts update.
                        .id(settings.currencyCode)
                }
            }
            .environmentObject(store)
            .environmentObject(subscriptions)
            .environmentObject(settings)
            .environmentObject(syncStatus)
            // A receipt or statement opened with the app ("Open in", or Open With on the Mac).
            .onOpenURL { url in
                Task { await SharedReceiptReader.open(url, into: store) }
            }
            .task(id: scenePhase) {
                // Receipts shared from other apps while this one was closed.
                if scenePhase == .active { await SharedReceiptReader.readDropped(into: store) }
                if scenePhase == .active {
                    // Launched while the phone was locked: read the files now, then sync.
                    if store.isWaitingForFiles || subscriptions.isWaitingForFiles {
                        let storeReady = store.reloadIfWaiting()
                        let contractsReady = subscriptions.reloadIfWaiting()
                        if storeReady && contractsReady { await startOrStopSync() }
                    }
                    await cloud?.refresh()
                }
            }
            .task(id: settings.iCloudSyncEnabled) { await startOrStopSync() }
            #if os(macOS)
            .task { MacLockWatcher.shared.watch(lock) }
            #endif
            .onChange(of: syncStatus.household) { _, link in store.householdRole = link.role }
            // Says what happened to files just shared, so nothing vanishes silently.
            .alert("Shared files", isPresented: Binding(get: { store.shareSummary != nil && (!settings.appLockEnabled || lock.isUnlocked) }, set: { if !$0 { store.shareSummary = nil } })) {
                Button("OK") { store.shareSummary = nil }
            } message: {
                Text(store.shareSummary ?? "")
            }
            .task(id: store.wealthAccounts.isEmpty) {
                await MonthlyCheckIn.schedule(enabled: settings.remindersEnabled, hasWealthAccounts: !store.wealthAccounts.isEmpty)
            }
            // A price rise shows up when a statement brings the new payment.
            .task(id: store.transactions.count) {
                await PriceRiseNotifier.check(subscriptions.priceRises(transactions: store.transactions), enabled: settings.remindersEnabled)
            }
            .task(id: subscriptions.contracts) {
                await ReminderScheduler.reschedule(subscriptions.contracts, enabled: settings.remindersEnabled)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                lock.lock()
            case .inactive:
                leftAt = leftAt ?? Date()
            case .active:
                // The Mac rarely goes to the background: lock after five minutes away instead.
                if let leftAt, Date().timeIntervalSince(leftAt) > 300 { lock.lock() }
                leftAt = nil
            @unknown default:
                break
            }
        }
        #if os(macOS)
        .defaultSize(width: 1360, height: 880)
        .commands { ImportFromDevicesCommands() }
        #endif
    }

    /// iCloud sync runs only when it is switched on, the build has iCloud, and not under tests.
    private func startOrStopSync() async {
        var testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        testing = testing || SampleData.isOn
        #endif
        guard settings.iCloudSyncEnabled, CloudSync.containerID != nil, !testing else {
            syncStatus.set(.off, pending: 0)
            syncStatus.sync = nil
            cloud = nil
            store.didPersist = nil
            subscriptions.didPersist = nil
            return
        }
        let sync = CloudSync(sources: [store, subscriptions], imagesFolder: store.imagesFolder, stateFolder: JSONFileStorage.defaultFolder, status: syncStatus)
        cloud = sync
        syncStatus.sync = sync
        ShareAcceptor.shared.setHandler { metadata in
            do {
                try await sync.accept(metadata)
                store.status = "You've joined the household."
            } catch {
                store.status = "Couldn't join the household: \(error.localizedDescription)"
            }
        }
        store.didPersist = { Task { await sync.localDataChanged() } }
        subscriptions.didPersist = { Task { await sync.localDataChanged() } }
        await sync.start()
    }
}
