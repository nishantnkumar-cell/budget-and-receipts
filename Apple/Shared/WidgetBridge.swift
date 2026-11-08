import BudgetCore
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps the widgets' summary up to date: after every save, the app writes the figures the
/// widgets show into the App Group and asks WidgetKit to redraw them.
@MainActor
enum WidgetBridge {
    static let showAmountsKey = "widgetsShowAmounts"
    static var showsAmounts: Bool { UserDefaults.standard.object(forKey: showAmountsKey) as? Bool ?? true }
    private static var pending: Task<Void, Never>?

    /// The widgets' figures for today: this month's safe to spend (the whole household) and the next bills.
    static func snapshot(store: BudgetStore, subscriptions: SubscriptionStore, today: Date = Date(), showAmounts: Bool = showsAmounts) -> WidgetSnapshot {
        let calculator = store.calculator
        let report = calculator.report(store.transactions, budgets: store.budgets, month: today)
        let upcoming = ComingUpPlanner().payments(store.bills(subscriptions.contracts), from: today)
        let safe = SafeToSpend.calculate(report: report, upcomingBills: upcoming, today: today, period: calculator.monthInterval(for: today))
        let bills = upcoming.filter { $0.kind == .payment && $0.date >= calculator.calendar.startOfDay(for: today) }
            .sorted { $0.date < $1.date }
            .prefix(5)
            .map { WidgetSnapshot.Bill(name: $0.vendor, date: $0.date, amount: $0.amount ?? 0) }
        guard showAmounts else {
            return WidgetSnapshot(updated: today, currency: AppSettings.currency, showsAmounts: false, bills: [])
        }
        return WidgetSnapshot(updated: today, currency: AppSettings.currency, showsAmounts: true,
                              safeToday: safe?.today, leftThisMonth: safe?.left, billsStillToCome: safe?.billsStillToCome,
                              daysLeft: safe?.daysLeft, spentThisMonth: report.spending, bills: Array(bills))
    }

    /// Writes a fresh summary shortly after changes stop (an import saves many times).
    static func scheduleRefresh() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            refreshNow()
        }
    }

    static func refreshNow() {
        let snapshot = snapshot(store: AppModel.store, subscriptions: AppModel.subscriptions)
        guard snapshot != WidgetSnapshot.read().map({ var old = $0; old.updated = snapshot.updated; return old }) else { return }
        snapshot.write()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
