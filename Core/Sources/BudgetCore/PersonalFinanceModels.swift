import Foundation

public struct MonthlyBudget: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var category: String
    public var limit: Decimal
    public var month: Date

    public init(id: UUID = UUID(), category: String, limit: Decimal, month: Date) {
        self.id = id
        self.category = category
        self.limit = limit
        self.month = month
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
    public static let all = [
        "Housing", "Bills & utilities", "Groceries", "Eating out", "Transport", "Shopping", "Health",
        "Family", "Subscriptions", "Travel", "Savings & investments", "Income", "Card payment",
        "Internal transfer", "Uncategorised"
    ]

    /// Categories that move money around rather than spend or earn it, so they have no budget.
    public static let nonBudget: Set<String> = ["Income", "Card payment", "Internal transfer", "Uncategorised"]

    public static var budgetable: [String] { all.filter { !nonBudget.contains($0) } }
}
