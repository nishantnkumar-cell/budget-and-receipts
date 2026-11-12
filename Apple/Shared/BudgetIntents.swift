import AppIntents
import BudgetCore
import Foundation

// Siri and Shortcuts: scan a receipt, how much is left, log a payment (an Apple Pay tap, via a
// Shortcuts automation) and ask your budget a question. Everything runs on this device.

/// "How much budget is left?"
struct BudgetLeftIntent: AppIntent {
    static let title: LocalizedStringResource = "Budget Left"
    static let description = IntentDescription("Says how much is left in this month's budgets, and how much is safe to spend today.")

    /// Figures are read out, so a locked iPhone must be unlocked first.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Category", description: "Leave empty for all your budgets.")
    var category: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        _ = AppModel.started
        if let locked = BudgetAnswers.appLockAnswer { return .result(value: locked, dialog: IntentDialog(stringLiteral: locked)) }
        let answer = BudgetAnswers.left(category: category, store: AppModel.store, subscriptions: AppModel.subscriptions)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

/// Logs a card payment as it happens. Made for the Shortcuts automation "When I tap Apple Pay"
/// (Wallet), which passes the merchant, amount and card. When the statement brings the same
/// payment in, the two become one.
struct LogPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Payment"
    static let description = IntentDescription("Adds a card payment now. When your statement brings it in, it joins that line instead of showing twice. Use it in a Shortcuts automation for Apple Pay (Wallet › Transaction).")

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Merchant")
    var merchant: String

    @Parameter(title: "Card", description: "The card's name from Wallet. It's matched to your accounts by name or last four digits.")
    var card: String?

    /// Allowed while the iPhone is locked, so the Apple Pay automation still works: it only
    /// adds a payment and repeats back what it was given, never anything already in the app.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant)") { \.$card }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = AppModel.started
        let store = AppModel.store
        guard amount.amount != 0 else { return .result(dialog: "There was no amount to log.") }
        let logged = store.logPayment(amount: amount.amount, currency: amount.currencyCode, merchant: merchant, card: card)
        return .result(dialog: IntentDialog(stringLiteral: "Logged \((-logged.amount).money) at \(logged.merchant)."))
    }
}

/// "Ask Duo Budget …": answered on this device from your own figures.
struct AskBudgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Your Budget"
    static let description = IntentDescription("Answers a question about your spending, budgets, bills or goals, on this device.")

    /// Answers are read out, so a locked iPhone must be unlocked first.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Question", requestValueDialog: "What would you like to know?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        _ = AppModel.started
        if let locked = BudgetAnswers.appLockAnswer { return .result(value: locked, dialog: IntentDialog(stringLiteral: locked)) }
        let answer = await BudgetAssistant.answer(question, store: AppModel.store, subscriptions: AppModel.subscriptions)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct DuoBudgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenScanIntent(), phrases: [
            "Scan a receipt with \(.applicationName)",
            "Scan a receipt in \(.applicationName)",
            "\(.applicationName) scan",
        ], shortTitle: "Scan Receipt", systemImageName: "doc.viewfinder")
        AppShortcut(intent: BudgetLeftIntent(), phrases: [
            "How much budget is left in \(.applicationName)",
            "What's left in \(.applicationName)",
            "\(.applicationName) budget left",
        ], shortTitle: "Budget Left", systemImageName: "gauge.with.dots.needle.67percent")
        AppShortcut(intent: AskBudgetIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask my budget in \(.applicationName)",
        ], shortTitle: "Ask Your Budget", systemImageName: "sparkles")
        AppShortcut(intent: LogPaymentIntent(), phrases: [
            "Log a payment in \(.applicationName)",
        ], shortTitle: "Log a Payment", systemImageName: "creditcard")
    }
}

/// Plain answers worked out from the stores, shared by Siri and the Ask screen.
@MainActor
enum BudgetAnswers {
    /// With the app lock on, Siri and Shortcuts don't read out figures: the app's own lock
    /// (Face ID inside the app) can't be asked for from Siri.
    static var appLockAnswer: String? {
        AppModel.settings.appLockEnabled ? "Duo Budget is locked. Open the app to see your budget." : nil
    }

    static func left(category: String?, store: BudgetStore, subscriptions: SubscriptionStore, today: Date = Date()) -> String {
        let report = store.calculator.report(store.transactions, budgets: store.budgets, month: today)
        if let category = category?.trimmingCharacters(in: .whitespaces), !category.isEmpty {
            guard let line = report.lines.first(where: { $0.category.localizedCaseInsensitiveContains(category) }) else {
                return "There's no \(category) budget yet."
            }
            guard let limit = line.limit, !line.isTentative else { return "You've spent \(line.spent.money) on \(line.category) this month, with no budget set." }
            let left = limit - line.spent
            return left >= 0 ? "\(left.money) left for \(line.category) this month, of \(limit.money)." : "\(line.category) is \((-left).money) over its \(limit.money) budget."
        }
        let upcoming = ComingUpPlanner().payments(store.bills(subscriptions.contracts), from: today)
        guard let safe = SafeToSpend.calculate(report: report, upcomingBills: upcoming, today: today, period: store.calculator.monthInterval(for: today)) else {
            return "Set a budget in Duo Budget first, then I can tell you what's left."
        }
        return "\(safe.left.money) left in this month's budgets. After \(safe.billsStillToCome.money) of bills to come, that's \(safe.today.money) a day for \(safe.daysLeft) days."
    }
}

/// Where the app should go next, from a widget, the Control Centre button or Siri.
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()
    init() {}
    /// The place to show. Root views move there and clear it.
    @Published var requested: AppSection?
    /// Opens the Ask your budget screen.
    @Published var asking = false

    /// Handles duobudget:// links. Returns false for anything else (files opened with the app).
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard url.scheme == "duobudget" else { return false }
        switch url.host() {
        case "scan": requested = .scan
        case "budgets": requested = .budgets
        case "plan": requested = .plan
        case "ask": asking = true
        default: requested = .home
        }
        return true
    }
}
