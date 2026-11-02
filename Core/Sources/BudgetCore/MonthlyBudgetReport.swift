import Foundation

/// Spending against the budget for one category in one month.
public struct CategoryBudgetLine: Identifiable, Hashable, Sendable {
    public var id: String { category }
    public let category: String
    /// Nil when no budget has been set for this category.
    public let limit: Decimal?
    public let spent: Decimal

    public init(category: String, limit: Decimal?, spent: Decimal) {
        self.category = category
        self.limit = limit
        self.spent = spent
    }

    public var remaining: Decimal? { limit.map { $0 - spent } }
    public var isOverBudget: Bool { limit.map { spent > $0 } ?? false }

    /// Spent as a share of the limit (1 = all used). Nil without a positive limit.
    public var progress: Double? {
        guard let limit, limit > 0 else { return nil }
        return NSDecimalNumber(decimal: spent / limit).doubleValue
    }
}

/// Income, spending and per-category budget lines for one calendar month.
public struct MonthlyBudgetReport: Hashable, Sendable {
    public let month: Date
    public let income: Decimal
    public let spending: Decimal
    public let lines: [CategoryBudgetLine]

    public init(month: Date, income: Decimal, spending: Decimal, lines: [CategoryBudgetLine]) {
        self.month = month
        self.income = income
        self.spending = spending
        self.lines = lines
    }

    public var net: Decimal { income - spending }
}

/// Money rules for months and budgets. Shared by every app, so keep it Foundation-only.
public struct BudgetCalculator: Sendable {
    public var calendar: Calendar

    /// Categories that move money between your own accounts. They are neither income nor spending.
    public static let transferCategories: Set<String> = ["Card payment", "Internal transfer"]

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func isInMonth(_ date: Date, _ month: Date) -> Bool {
        calendar.isDate(date, equalTo: month, toGranularity: .month)
    }

    /// Spending per category for the month. Approved receipt splits count in their own
    /// categories. A credit in a spending category (a refund) reduces that category.
    public func spendingByCategory(_ transactions: [BankTransaction], month: Date) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for transaction in transactions where isInMonth(transaction.date, month) {
            for (category, amount) in allocations(of: transaction) {
                totals[category, default: 0] += amount
            }
        }
        return totals
    }

    /// Money coming in this month: credits that are not refunds or transfers.
    public func income(_ transactions: [BankTransaction], month: Date) -> Decimal {
        transactions
            .filter { isInMonth($0.date, month) && isIncome($0) }
            .reduce(0) { $0 + $1.amount }
    }

    public func report(_ transactions: [BankTransaction], budgets: [MonthlyBudget], month: Date) -> MonthlyBudgetReport {
        let spent = spendingByCategory(transactions, month: month)
        let categories = FinanceCategories.budgetable.filter { budget(for: $0, in: budgets, month: month) != nil || spent[$0] != nil }
        let lines = categories.map { category in
            CategoryBudgetLine(category: category, limit: effectiveLimit(for: category, transactions: transactions, budgets: budgets, month: month), spent: spent[category] ?? 0)
        }
        return MonthlyBudgetReport(
            month: month,
            income: income(transactions, month: month),
            spending: spent.values.reduce(0, +),
            lines: lines
        )
    }

    /// The budget for a category in a month. A budget carries forward to later months
    /// until a newer one is set, so you do not have to re-enter it every month.
    public func budget(for category: String, in budgets: [MonthlyBudget], month: Date) -> MonthlyBudget? {
        guard let monthStart = calendar.dateInterval(of: .month, for: month)?.start else { return nil }
        return budgets
            .filter { $0.category == category && (calendar.dateInterval(of: .month, for: $0.month)?.start ?? $0.month) <= monthStart }
            .max { $0.month < $1.month }
    }

    /// The limit for a month, including last month's leftover when the budget rolls over.
    /// Rollover looks back at most 12 months and stops at the first month with no budget.
    public func effectiveLimit(for category: String, transactions: [BankTransaction], budgets: [MonthlyBudget], month: Date, depth: Int = 0) -> Decimal? {
        guard let current = budget(for: category, in: budgets, month: month) else { return nil }
        guard current.rollover == true, depth < 12,
              let previousMonth = calendar.date(byAdding: .month, value: -1, to: month),
              let previousLimit = effectiveLimit(for: category, transactions: transactions, budgets: budgets, month: previousMonth, depth: depth + 1)
        else { return current.limit }
        let previousSpent = spendingByCategory(transactions, month: previousMonth)[category] ?? 0
        return current.limit + (previousLimit - previousSpent)
    }

    private func isIncome(_ transaction: BankTransaction) -> Bool {
        transaction.amount > 0
            && !Self.transferCategories.contains(transaction.category)
            && !FinanceCategories.budgetable.contains(transaction.category)
    }

    /// Signed spending per category: positive for a purchase, negative for a refund.
    func allocations(of transaction: BankTransaction) -> [(String, Decimal)] {
        guard transaction.amount != 0, !Self.transferCategories.contains(transaction.category) else { return [] }
        let isDebit = transaction.amount < 0
        if transaction.splits.isEmpty {
            // An uncategorised or income credit is income, not a refund.
            if !isDebit && !FinanceCategories.budgetable.contains(transaction.category) { return [] }
            if transaction.category == "Income" { return [] }
            return [(transaction.category, -transaction.amount)]
        }
        return transaction.splits.map { ($0.category, isDebit ? $0.amount : -$0.amount) }
    }
}
