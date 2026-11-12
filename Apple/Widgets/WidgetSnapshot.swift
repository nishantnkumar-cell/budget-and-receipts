import Foundation

/// What the widgets show, written by the app into the App Group whenever its data changes.
/// Widgets can't open the app's own files, so they read this small summary instead. It holds
/// no payments, only the figures on the widgets, and none at all when amounts are hidden.
struct WidgetSnapshot: Codable, Equatable {
    struct Bill: Codable, Equatable, Hashable {
        var name: String
        var date: Date
        var amount: Decimal
    }

    var updated: Date
    var currency: String
    /// False when Settings hides amounts from widgets: they then just open the app.
    var showsAmounts: Bool
    /// What can be spent each day for the rest of the month, after bills. Nil without budgets.
    var safeToday: Decimal?
    /// Left in this month's budgets, before bills still to come.
    var leftThisMonth: Decimal?
    var billsStillToCome: Decimal?
    var daysLeft: Int?
    var spentThisMonth: Decimal?
    /// The next few bills, soonest first.
    var bills: [Bill]

    static let fileName = "widget-snapshot.json"
    static let kinds = (safeToSpend: "SafeToSpend", nextBill: "NextBill")

    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedReceiptDrop.appGroup)?.appendingPathComponent(fileName) }

    static func read() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Saves it for the widgets. Returns false when the App Group isn't there (unsigned builds).
    @discardableResult
    func write() -> Bool {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return false }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        guard (try? data.write(to: url, options: options)) != nil else { return false }
        // Bill names and amounts: left out of iCloud device Backup, like the app's own files.
        var saved = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? saved.setResourceValues(values)
        return true
    }

    func money(_ value: Decimal) -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(value.isWhole ? 0 : 2)))
    }

    static let placeholder = WidgetSnapshot(
        updated: Date(), currency: Locale.current.currency?.identifier ?? "GBP", showsAmounts: true,
        safeToday: 32, leftThisMonth: 640, billsStillToCome: 120, daysLeft: 16, spentThisMonth: 1210,
        bills: [Bill(name: "Netflix", date: Date().addingTimeInterval(86_400 * 2), amount: Decimal(string: "10.99")!),
                Bill(name: "Council tax", date: Date().addingTimeInterval(86_400 * 5), amount: 162)]
    )
}

extension Decimal {
    var isWhole: Bool {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return rounded == self
    }
}
