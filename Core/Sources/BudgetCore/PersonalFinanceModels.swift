import Foundation

public struct MonthlyBudget: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var category: String
    public var limit: Decimal
    public var month: Date
    /// When true, money left unspent (or overspent) last month is added to this month's limit.
    /// Optional so budgets saved before this setting existed still load.
    public var rollover: Bool?

    public init(id: UUID = UUID(), category: String, limit: Decimal, month: Date, rollover: Bool? = nil) {
        self.id = id
        self.category = category
        self.limit = limit
        self.month = month
        self.rollover = rollover
    }
}

public struct ImportRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fileName: String
    public var importedAt: Date
    public var transactionCount: Int
    public var status: String

    public init(id: UUID = UUID(), fileName: String, importedAt: Date = Date(), transactionCount: Int, status: String) {
        self.id = id
        self.fileName = fileName
        self.importedAt = importedAt
        self.transactionCount = transactionCount
        self.status = status
    }
}

public enum FinanceCategories {
    /// Checked against the defaults of UK budgeting apps (Monzo, Starling, Emma): cash,
    /// entertainment, gifts and charity, personal care, education and fees were missing.
    public static let all = [
        "Housing", "Bills & utilities", "Groceries", "Eating out", "Transport", "Shopping", "Health",
        "Personal care", "Family", "Entertainment", "Subscriptions", "Travel", "Education",
        "Gifts & charity", "Cash", "Fees & charges", "Savings & investments", "Income", "Card payment",
        "Internal transfer", "Uncategorised"
    ]

    /// Categories that move money around rather than spend or earn it, so they have no budget.
    /// Savings are your own money put aside, so they aren't spending either.
    public static let nonBudget: Set<String> = ["Income", "Card payment", "Internal transfer", "Savings & investments", "Uncategorised"]

    public static var budgetable: [String] { all.filter { !nonBudget.contains($0) } }
}
