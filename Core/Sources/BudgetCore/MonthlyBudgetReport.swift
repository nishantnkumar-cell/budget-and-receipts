import Foundation

/// Spending against the budget for one category in one month.
public struct CategoryBudgetLine: Identifiable, Hashable, Sendable {
    public var id: String { category }
    public let category: String
    /// Nil when no budget has been set for this category and there's no history to suggest one.
    public let limit: Decimal?
    public let spent: Decimal
    /// True when the limit isn't one you set but your average spending over recent months.
    public let isTentative: Bool

    public init(category: String, limit: Decimal?, spent: Decimal, isTentative: Bool = false) {
        self.category = category
        self.limit = limit
        self.spent = spent
        self.isTentative = isTentative
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
    /// Money moving between your own accounts, cards and savings: neither spending nor income.
    public static let transferCategories: Set<String> = ["Card payment", "Internal transfer", "Savings & investments"]

    /// The day a budget month starts, for people who budget from payday (1 = calendar months).
    /// The month "November" with a start day of 25 runs from 25 October to 24 November.
    public var monthStartDay: Int

    public init(calendar: Calendar = .current, monthStartDay: Int = 1) {
        self.calendar = calendar
        self.monthStartDay = min(max(monthStartDay, 1), 28)
    }

    public func isInMonth(_ date: Date, _ month: Date) -> Bool {
        guard monthStartDay > 1 else { return calendar.isDate(date, equalTo: month, toGranularity: .month) }
        return monthInterval(for: month).contains(date)
    }

    /// The dates a budget month covers.
    public func monthInterval(for month: Date) -> DateInterval {
        guard let calendarMonth = calendar.dateInterval(of: .month, for: month) else { return DateInterval(start: month, duration: 0) }
        guard monthStartDay > 1,
              let previous = calendar.date(byAdding: .month, value: -1, to: calendarMonth.start),
              let start = calendar.date(bySetting: .day, value: monthStartDay, of: previous),
              let end = calendar.date(bySetting: .day, value: monthStartDay, of: calendarMonth.start) else { return calendarMonth }
        return DateInterval(start: calendar.startOfDay(for: start), end: calendar.startOfDay(for: end))
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
        let averages = averageSpending(transactions, before: month)
        let categories = FinanceCategories.budgetable.filter { budget(for: $0, in: budgets, month: month) != nil || spent[$0] != nil || averages[$0] != nil }
        let lines = categories.map { category in
            if let limit = effectiveLimit(for: category, transactions: transactions, budgets: budgets, month: month) {
                return CategoryBudgetLine(category: category, limit: limit, spent: spent[category] ?? 0)
            }
            // No budget set: your average over recent months stands in, marked as tentative.
            return CategoryBudgetLine(category: category, limit: averages[category], spent: spent[category] ?? 0, isTentative: averages[category] != nil)
        }
        return MonthlyBudgetReport(
            month: month,
            income: income(transactions, month: month),
            spending: spent.values.reduce(0, +),
            lines: lines
        )
    }

    /// Average monthly spending per category over up to three months before `month`, counting
    /// only months with any transactions (so a new user's first month isn't divided by three).
    /// Rounded to whole pounds; categories averaging nothing are left out.
    public func averageSpending(_ transactions: [BankTransaction], before month: Date, months: Int = 3) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        var monthsWithData = 0
        for back in 1...months {
            guard let earlier = calendar.date(byAdding: .month, value: -back, to: month) else { continue }
            guard transactions.contains(where: { isInMonth($0.date, earlier) }) else { continue }
            monthsWithData += 1
            for (category, amount) in spendingByCategory(transactions, month: earlier) where FinanceCategories.budgetable.contains(category) {
                totals[category, default: 0] += amount
            }
        }
        guard monthsWithData > 0 else { return [:] }
        return totals.compactMapValues { total in
            var average = total / Decimal(monthsWithData)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &average, 0, .plain)
            return rounded > 0 ? rounded : nil
        }
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

    /// Money earned: credits that aren't transfers or refunds. A refund the app couldn't put
    /// back in its shop's category (Income › Refund) is money back, not earnings.
    private func isIncome(_ transaction: BankTransaction) -> Bool {
        transaction.amount > 0
            && !Self.transferCategories.contains(transaction.category)
            && !FinanceCategories.budgetable.contains(transaction.category)
            && !(transaction.category == "Income" && transaction.subcategory == "Refund")
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
