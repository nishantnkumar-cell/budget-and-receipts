import BudgetCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// "Ask your budget". The figures are worked out exactly from your data (`BudgetFacts`);
/// Apple's on-device model only reads them and words the answer. Nothing leaves the device,
/// and no cloud AI is used. Without Apple Intelligence, simple questions still get answers.
@MainActor
enum BudgetAssistant {
    static var isOn: Bool { UserDefaults.standard.object(forKey: "askBudgetAI") as? Bool ?? true }

    static func facts(store: BudgetStore, subscriptions: SubscriptionStore, today: Date = Date()) -> BudgetFacts {
        let month = today
        let report = store.calculator.report(store.transactions, budgets: store.budgets, month: month)
        let upcoming = ComingUpPlanner().payments(store.bills(subscriptions.contracts), from: today)
        let safe = SafeToSpend.calculate(report: report, upcomingBills: upcoming, today: today, period: store.calculator.monthInterval(for: month))
        var facts = BudgetFacts.make(transactions: store.transactions, budgets: store.budgets, month: month, calculator: store.calculator,
                                     safeToSpend: safe, bills: upcoming, currency: AppSettings.currency)
        facts.goals = store.goals.map { ($0.name, $0.saved, $0.target) }
        return facts
    }

    static func answer(_ question: String, store: BudgetStore, subscriptions: SubscriptionStore) async -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return "Ask about your spending, budgets, shops, bills or goals." }
        let facts = facts(store: store, subscriptions: subscriptions)
        // Sums like "can I afford £50" are worked out exactly here, not by the model.
        if let afford = facts.affordAnswer(to: question) { return afford }
        #if canImport(FoundationModels)
        if isOn, ReceiptAIService.unavailableReason == nil {
            let session = LanguageModelSession(instructions: """
                You answer questions about a person's own budget, using only the facts given. Every amount is \
                already worked out: copy amounts exactly as written and never add, estimate or invent figures. \
                If the facts don't cover the question, say so briefly and suggest what you can answer. Reply in \
                one or two short, friendly sentences, speaking to the person as "you". Today is \(Date().formatted(date: .complete, time: .omitted)).
                """)
            if let response = try? await session.respond(to: "Facts:\n\(facts.sheet)\n\nQuestion: \(question)") {
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        #endif
        return facts.simpleAnswer(to: question)
            ?? "I can answer questions like \"How much is left?\", \"What did I spend on groceries?\" or \"When's the next bill?\""
    }

    /// Why the model isn't being used, for the Ask screen. Nil when it is.
    static var limitation: String? {
        guard isOn else { return "Apple Intelligence is off for questions in Settings, so only simple questions are answered." }
        return ReceiptAIService.unavailableReason.map { "\($0) Simple questions are still answered." }
    }
}
