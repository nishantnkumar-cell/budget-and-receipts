import Foundation

/// A comment or reaction on a transaction, so a couple can talk about a payment in place.
public struct TransactionNote: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var transactionID: String
    /// Who wrote it, from the household owner's side (flipped on the partner's phone).
    public var author: Person
    public var text: String
    /// A single emoji reaction instead of (or as well as) text.
    public var reaction: String?
    public var date: Date

    public init(id: UUID = UUID(), transactionID: String, author: Person = .me, text: String = "", reaction: String? = nil, date: Date = Date()) {
        self.id = id
        self.transactionID = transactionID
        self.author = author
        self.text = text
        self.reaction = reaction
        self.date = date
    }
}

/// Money to put aside each month so yearly (or quarterly) bills are covered when they come.
public struct SetAside: Identifiable, Hashable, Sendable {
    public var id: UUID { contractID }
    public let contractID: UUID
    public let vendor: String
    public let dueDate: Date
    public let amount: Decimal
    public let monthly: Decimal

    /// For each active bill paid less often than monthly: its amount over the months until it's due.
    public static func plan(_ contracts: [SubscriptionContract], now: Date = Date(), calendar: Calendar = .current) -> [SetAside] {
        contracts.filter { $0.status == .active && [.quarterly, .halfYearly, .yearly].contains($0.billingPeriod) }.compactMap { contract in
            let due = ComingUpPlanner(calendar: calendar, paymentDays: 400).payments([contract], from: now).first?.date ?? contract.nextPaymentDueDate
            guard due >= calendar.startOfDay(for: now) else { return nil }
            let months = max(1, calendar.dateComponents([.month], from: calendar.startOfDay(for: now), to: due).month ?? 1)
            var monthly = contract.expectedAmount / Decimal(months)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &monthly, 2, .up)
            return SetAside(contractID: contract.id, vendor: contract.vendor, dueDate: due, amount: contract.expectedAmount, monthly: rounded)
        }.sorted { $0.dueDate < $1.dueDate }
    }
}

/// A short look back at a month: totals, what changed, what went over.
public struct MonthReview: Hashable, Sendable {
    public struct CategoryChange: Hashable, Sendable {
        public let category: String
        public let spent: Decimal
        public let previous: Decimal
        public var change: Decimal { spent - previous }
    }

    public let month: Date
    public let income: Decimal
    public let spending: Decimal
    public let previousSpending: Decimal
    /// The three biggest spending categories, with last month's figure beside them.
    public let topCategories: [CategoryChange]
    public let overBudget: [String]
    public let biggestPurchase: BankTransaction?

    public var spendingChange: Decimal { spending - previousSpending }

    public static func make(_ transactions: [BankTransaction], budgets: [MonthlyBudget], month: Date, calculator: BudgetCalculator = BudgetCalculator()) -> MonthReview {
        let report = calculator.report(transactions, budgets: budgets, month: month)
        let previousMonth = calculator.calendar.date(byAdding: .month, value: -1, to: month) ?? month
        let previous = calculator.spendingByCategory(transactions, month: previousMonth)
        let current = calculator.spendingByCategory(transactions, month: month)
        let top = current.sorted { $0.value > $1.value }.prefix(3).map {
            CategoryChange(category: $0.key, spent: $0.value, previous: previous[$0.key] ?? 0)
        }
        let biggest = transactions
            .filter { calculator.isInMonth($0.date, month) && $0.amount < 0 && !BudgetCalculator.transferCategories.contains($0.category) }
            .min { $0.amount < $1.amount }
        return MonthReview(
            month: month,
            income: report.income,
            spending: report.spending,
            previousSpending: previous.values.reduce(0, +),
            topCategories: top,
            overBudget: report.lines.filter { $0.isOverBudget && !$0.isTentative }.map(\.category),
            biggestPurchase: biggest
        )
    }
}

public extension Categoriser {
    /// Other uncategorised transactions from the same merchant, so one correction can fix them all.
    static func similarUncategorised(to transaction: BankTransaction, in transactions: [BankTransaction]) -> [BankTransaction] {
        let key = merchantKey(transaction.merchant)
        guard !key.isEmpty else { return [] }
        return transactions.filter { $0.id != transaction.id && $0.category == "Uncategorised" && $0.splits.isEmpty && merchantKey($0.merchant) == key }
    }
}
