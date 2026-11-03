import SwiftUI

@main
struct BudgetReceiptsApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    // The stores live in AppModel, so a background wake-up (an iCloud push or a background
    // refresh, with no screen) can sync them too.
    @StateObject private var store = AppModel.store
    @StateObject private var subscriptions = AppModel.subscriptions
    @StateObject private var settings = AppModel.settings
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var syncStatus = AppModel.syncStatus
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
                if scenePhase == .active {
                    await SharedReceiptReader.readDropped(into: store)
                    SharedReceiptReader.importWaitingStatements(into: store)
                }
                if scenePhase == .active {
                    // Launched while the phone was locked: read the files now, then sync.
                    if store.isWaitingForFiles || subscriptions.isWaitingForFiles {
                        let storeReady = store.reloadIfWaiting()
                        let contractsReady = subscriptions.reloadIfWaiting()
                        if storeReady && contractsReady { await AppModel.startOrStopSync() }
                    }
                    await AppModel.cloud?.refresh()
                    // Payments synced from other devices get categories too, not only imports.
                    Task { await store.categoriseUnknownMerchants() }
                }
            }
            .task(id: settings.iCloudSyncEnabled) { await AppModel.startOrStopSync() }
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
                #if os(iOS)
                BackgroundSync.schedule()
                #endif
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
        #if os(iOS)
        // Every few hours iOS gives the app a moment, even with the phone locked, to sync.
        .backgroundTask(.appRefresh(BackgroundSync.identifier)) {
            await AppModel.syncInBackground()
            await MainActor.run { BackgroundSync.schedule() }
        }
        #endif
        #if os(macOS)
        .defaultSize(width: 1360, height: 880)
        .commands { ImportFromDevicesCommands() }
        #endif
    }
}

/// The app's data and its iCloud sync, made once at launch. Kept outside the SwiftUI scene so
/// that a background wake-up, which has no screen, can still read the files and sync.
@MainActor
enum AppModel {
    #if DEBUG
    static let store = SampleData.isOn ? SampleData.budgetStore() : BudgetStore()
    static let subscriptions = SampleData.isOn ? SampleData.subscriptionStore() : SubscriptionStore()
    #else
    static let store = BudgetStore()
    static let subscriptions = SubscriptionStore()
    #endif
    static let settings = AppSettings()
    static let syncStatus = SyncStatus()
    private(set) static var cloud: CloudSync?

    /// iCloud sync runs only when it is switched on, the build has iCloud, and not under tests.
    static func startOrStopSync() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-WipeICloud") {
            await CloudSync.wipeICloud(stateFolder: JSONFileStorage.defaultFolder)
            exit(0)
        }
        #endif
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
        guard cloud == nil else { return }
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

    /// A background wake-up: start sync if it isn't running, then fetch and send.
    static func syncInBackground() async {
        if store.isWaitingForFiles || subscriptions.isWaitingForFiles {
            guard store.reloadIfWaiting(), subscriptions.reloadIfWaiting() else { return }
        }
        if cloud == nil { await startOrStopSync() }
        await cloud?.refresh()
        await cloud?.localDataChanged()
    }
}
