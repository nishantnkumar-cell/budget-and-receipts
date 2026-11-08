import SwiftUI
import CloudKit

@main
struct BudgetReceiptsApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    // The stores live in AppModel, so a background wake-up (an iCloud push or a background
    // refresh, with no screen) can sync them too.
    @StateObject private var store = { _ = AppModel.started; return AppModel.store }()
    @StateObject private var subscriptions = AppModel.subscriptions
    @StateObject private var settings = AppModel.settings
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var syncStatus = AppModel.syncStatus
    @StateObject private var navigator = AppNavigator.shared
    /// When the app last stopped being in front, to lock the Mac after a while away.
    @State private var leftAt: Date?
    /// The one-time welcome sheet on a new install.
    @State private var showWelcome = false

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
                        .task { showWelcome = WelcomeView.shouldShow(store: store) }
                        .sheet(isPresented: $showWelcome, onDismiss: { UserDefaults.standard.set(true, forKey: WelcomeView.shownKey) }) {
                            WelcomeView()
                                .environmentObject(store)
                                .environmentObject(subscriptions)
                                .environmentObject(settings)
                                .environmentObject(syncStatus)
                        }
                }
            }
            #if os(macOS)
            // Files opened with the app go to the open window instead of each opening a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            #endif
            .environmentObject(store)
            .environmentObject(subscriptions)
            .environmentObject(settings)
            .environmentObject(syncStatus)
            // A receipt or statement opened with the app ("Open in", or Open With on the Mac).
            .onOpenURL { url in
                if AppNavigator.shared.open(url) { return }
                Task { await SharedReceiptReader.open(url, into: store) }
            }
            .environmentObject(navigator)
            .sheet(isPresented: $navigator.asking) {
                NavigationStack { AskBudgetView() }
                    .environmentObject(store)
                    .environmentObject(subscriptions)
            }
            .task(id: scenePhase) {
                // Receipts shared from other apps while this one was closed.
                if scenePhase == .active {
                    await SharedReceiptReader.readDropped(into: store)
                    #if DEBUG
                    // Testing only: files copied into Documents/Import over the cable count as shared.
                    if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        let folder = documents.appendingPathComponent("Import", isDirectory: true)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        await SharedReceiptReader.readDropped(into: store, folder: folder)
                    }
                    #endif
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
                    // Payments synced from other devices get categories too, not only imports:
                    // rules first (they also fill in sub-categories), then Apple Intelligence.
                    store.applyRules()
                    Task { await store.categoriseUnknownMerchants() }
                }
            }
            .task(id: settings.iCloudSyncEnabled) { await AppModel.startOrStopSync() }
            // Joining a partner's household says what happened, even when it fails.
            .alert(syncStatus.invite?.title ?? "", isPresented: Binding(
                get: { syncStatus.invite != nil && syncStatus.invite != .joining },
                set: { if !$0 { syncStatus.invite = nil } }
            )) {
                Button("OK") { syncStatus.invite = nil }
            } message: {
                Text(syncStatus.invite?.message ?? "")
            }
            .overlay(alignment: .top) {
                if syncStatus.invite == .joining {
                    Label("Joining the household…", systemImage: "person.2.badge.gearshape")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
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
                WidgetBridge.scheduleRefresh()
            }
            // Widgets move on a day and pick up anything changed while the app was away.
            .task(id: scenePhase) { if scenePhase == .active { WidgetBridge.scheduleRefresh() } }
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
        // One window each launch, not every window that was ever opened.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
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
    /// Sets up what has to be ready before any screen (or a Siri request) uses the stores.
    static let started: Void = {
        store.didChange = { WidgetBridge.scheduleRefresh() }
    }()
    static let syncStatus = SyncStatus()
    private(set) static var cloud: CloudSync?

    /// iCloud sync runs only when it is switched on, the build has iCloud, and not under tests.
    static func startOrStopSync() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-WipeICloud") {
            // Testing only: also clears this device's data, so nothing old is sent again.
            if ProcessInfo.processInfo.arguments.contains("-AndLocalData") {
                store.didPersist = nil
                subscriptions.didPersist = nil
                store.resetAllData()
                subscriptions.resetAllData()
            }
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
                syncStatus.invite = .joined(syncStatus.household.sharedBy)
            } catch {
                store.status = "Couldn't join the household: \(error.localizedDescription)"
                syncStatus.invite = .failed(Self.inviteFailure(error))
            }
        }
        store.didPersist = { Task { await sync.localDataChanged() } }
        subscriptions.didPersist = { Task { await sync.localDataChanged() } }
        await sync.start()
    }

    /// Why joining failed, in words the person can act on.
    static func inviteFailure(_ error: Error) -> String {
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated:
                return "This iPhone isn't signed in to iCloud, or iCloud Drive is off. Check Settings › your name › iCloud, then open the invitation again."
            case .networkUnavailable, .networkFailure:
                return "There's no internet connection. Open the invitation again when you're online."
            case .unknownItem, .participantMayNeedVerification:
                return "This invitation was sent to a different Apple ID, or it has been withdrawn. Ask for a new one and open it on this iPhone. (\(CloudSync.describe(error)))"
            default:
                return CloudSync.describe(error)
            }
        }
        return error.localizedDescription
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
