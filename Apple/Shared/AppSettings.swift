import BudgetCore
import LocalAuthentication
import SwiftUI
import UserNotifications

/// Small per-device preferences, kept in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let supportedCurrencies = ["GBP", "EUR", "USD", "INR", "AUD", "CAD", "CHF", "JPY"]

    /// The currency code views format money with. Read directly so formatting code stays simple.
    nonisolated static var currency: String {
        UserDefaults.standard.string(forKey: Keys.currency) ?? Locale.current.currency?.identifier ?? "GBP"
    }

    @Published var currencyCode: String { didSet { defaults.set(currencyCode, forKey: Keys.currency) } }
    @Published var appLockEnabled: Bool { didSet { defaults.set(appLockEnabled, forKey: Keys.appLock) } }
    @Published var remindersEnabled: Bool { didSet { defaults.set(remindersEnabled, forKey: Keys.reminders) } }
    /// Use Apple Intelligence on the device for receipts the normal reading gets wrong. On by default.
    @Published var smartReceiptsEnabled: Bool { didSet { defaults.set(smartReceiptsEnabled, forKey: Keys.smartReceipts) } }

    /// Keep data in step across your devices with iCloud. On by default where iCloud is available.
    @Published var iCloudSyncEnabled: Bool { didSet { defaults.set(iCloudSyncEnabled, forKey: Keys.iCloudSync) } }

    /// Suggest categories for unknown merchants with Apple Intelligence on the device. On by default.
    @Published var aiCategoriesEnabled: Bool { didSet { defaults.set(aiCategoriesEnabled, forKey: Keys.aiCategories) } }
    /// Look up unknown merchants with Apple Maps (sends the name and town). Off until switched on.
    @Published var onlineCategoriesEnabled: Bool { didSet { defaults.set(onlineCategoriesEnabled, forKey: Keys.onlineCategories) } }

    /// The day budget months start, e.g. 25 for payday on the 25th. 1 means calendar months.
    @Published var monthStartDay: Int { didSet { defaults.set(monthStartDay, forKey: Keys.monthStartDay) } }
    nonisolated static var monthStartDay: Int { max(1, UserDefaults.standard.integer(forKey: Keys.monthStartDay)) }

    nonisolated static var aiCategories: Bool { UserDefaults.standard.object(forKey: Keys.aiCategories) as? Bool ?? true }
    nonisolated static var onlineCategories: Bool { UserDefaults.standard.bool(forKey: Keys.onlineCategories) }

    nonisolated static var smartReceipts: Bool {
        UserDefaults.standard.object(forKey: Keys.smartReceipts) as? Bool ?? true
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let currency = "currencyCode"
        static let appLock = "appLockEnabled"
        static let reminders = "remindersEnabled"
        static let smartReceipts = "smartReceiptsEnabled"
        static let iCloudSync = "iCloudSyncEnabled"
        static let monthStartDay = "monthStartDay"
        static let aiCategories = "aiCategoriesEnabled"
        static let onlineCategories = "onlineCategoriesEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        currencyCode = defaults.string(forKey: Keys.currency) ?? Locale.current.currency?.identifier ?? "GBP"
        appLockEnabled = defaults.bool(forKey: Keys.appLock)
        remindersEnabled = defaults.bool(forKey: Keys.reminders)
        smartReceiptsEnabled = defaults.object(forKey: Keys.smartReceipts) as? Bool ?? true
        iCloudSyncEnabled = defaults.object(forKey: Keys.iCloudSync) as? Bool ?? true
        aiCategoriesEnabled = defaults.object(forKey: Keys.aiCategories) as? Bool ?? true
        monthStartDay = max(1, defaults.integer(forKey: Keys.monthStartDay))
        onlineCategoriesEnabled = defaults.bool(forKey: Keys.onlineCategories)
    }
}

/// Face ID, Touch ID or the device passcode in front of the app.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published var message: String?

    /// False when the device has no passcode or biometrics, so the lock can't work.
    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// "Face ID", "Touch ID" or "Passcode", for button labels.
    var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func lock() { isUnlocked = false }

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode or biometrics on this device: the lock cannot work, so do not trap the person out.
            isUnlocked = true
            message = error?.localizedDescription
            return
        }
        do {
            isUnlocked = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your budget")
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

struct LockScreen: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 48)).foregroundStyle(Color.brandPlum)
            Text("Duo Budget is locked").font(.title2.bold())
            Button("Unlock with \(lock.methodName)") { Task { await lock.unlock() } }
                .buttonStyle(.borderedProminent)
            if let message = lock.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await lock.unlock() }
    }
}

/// Turns the contract reminders worked out in BudgetCore into local notifications.
enum ReminderScheduler {
    private static let prefix = "contract."

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces every scheduled contract reminder with the current set. Pass an empty list to clear them.
    static func reschedule(_ contracts: [SubscriptionContract], covers: [ProductCover] = [], enabled: Bool, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard enabled else { return }

        // iOS keeps at most 64 pending notifications per app; keep the soonest.
        let planner = ReminderPlanner()
        let all = (planner.reminders(for: contracts, now: now) + planner.reminders(for: covers, now: now)).sorted { $0.fireDate < $1.fireDate }
        for reminder in all.prefix(60) {
            let content = UNMutableNotificationContent()
            // With the app lock on, the lock screen shouldn't show vendors or amounts.
            let private_ = UserDefaults.standard.bool(forKey: "appLockEnabled")
            content.title = private_ ? "Duo Budget" : reminder.title
            content.body = private_ ? "You have a payment, contract or receipt date coming up." : reminder.body
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let request = UNNotificationRequest(identifier: prefix + reminder.identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }
}

/// On the 1st of each month: a nudge to update balances more than 30 days old, and to look
/// at the month in review.
enum MonthlyCheckIn {
    static func schedule(enabled: Bool, hasWealthAccounts: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["monthly-check-in"])
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your month in review"
        content.body = hasWealthAccounts
            ? "See how last month went, and update any balances that are out of date."
            : "See how last month went."
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(day: 1, hour: 9), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: "monthly-check-in", content: content, trigger: trigger))
    }
}

/// A local notification the first time a subscription or bill's price goes up.
enum PriceRiseNotifier {
    static func check(_ rises: [UUID: PriceRise], enabled: Bool, defaults: UserDefaults = .standard) async {
        guard enabled else { return }
        var told = Set(defaults.stringArray(forKey: "notifiedPriceRises") ?? [])
        let hidden = defaults.bool(forKey: "appLockEnabled")
        for rise in rises.values {
            let key = "\(rise.contractID)|\(rise.latest)"
            guard told.insert(key).inserted else { continue }
            let content = UNMutableNotificationContent()
            content.title = hidden ? "Duo Budget" : "\(rise.vendor) costs more"
            content.body = hidden
                ? "A subscription or bill has gone up in price."
                : "Now \(rise.latest.formatted(.currency(code: AppSettings.currency))), up from \(rise.previous.formatted(.currency(code: AppSettings.currency))). Check it in Plan."
            let request = UNNotificationRequest(identifier: "price-rise-\(key)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
        defaults.set(Array(told), forKey: "notifiedPriceRises")
    }
}
