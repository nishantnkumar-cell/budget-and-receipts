import BudgetCore
import SwiftUI

@MainActor
final class BudgetStore: ObservableObject {
    @Published var transactions: [BankTransaction] = []
    @Published var changes: [ChangeRecord] = []
    @Published var budgets: [MonthlyBudget] = []
    @Published var imports: [ImportRecord] = []
    @Published var status = "Import statements or add a transaction."

    private let storage: JSONFileStorage

    /// - Parameter folder: where the JSON files live. Tests pass a temporary folder;
    ///   the app uses Application Support.
    init(folder: URL = JSONFileStorage.defaultFolder) {
        storage = JSONFileStorage(folder: folder)
        transactions = storage.load("transactions.json") ?? []
        changes = storage.load("changes.json") ?? []
        budgets = storage.load("budgets.json") ?? []
        imports = storage.load("imports.json") ?? []
    }

    func saveDraft(_ draft: SplitDraft, for transaction: BankTransaction) {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        transactions[index].pendingSplitDraft = draft
        persist()
        status = "Draft saved. No splits were created."
    }

    /// Approves a receipt split. Every approval goes through `SplitApprovalPolicy`.
    @discardableResult
    func approve(_ draft: SplitDraft, for transaction: BankTransaction) -> Result<Void, SplitApprovalFailure> {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return .failure(.noItems) }
        let result = SplitApprovalPolicy().validate(draft, bankAmount: transactions[index].amount, reviewed: draft.receipt.reviewed)
        if case .failure(let failure) = result {
            status = "Approval blocked: \(failure.explanation)"
            return result
        }
        transactions[index].splits = draft.proposedSplits
        transactions[index].pendingSplitDraft = nil
        changes.append(ChangeRecord(date: Date(), transactionID: transaction.id, reason: "Approved receipt split after manual review"))
        persist()
        status = "Approved and created \(draft.proposedSplits.count) splits."
        return result
    }

    func addTransaction() {
        let transaction = BankTransaction(
            date: Date(),
            merchant: "New transaction",
            description: "Manual entry",
            amount: 0,
            category: "Uncategorised",
            fingerprint: UUID().uuidString
        )
        transactions.insert(transaction, at: 0)
        persist()
    }

    func update(_ transaction: BankTransaction) {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        transactions[index] = transaction
        persist()
    }

    func delete(_ transaction: BankTransaction) {
        transactions.removeAll { $0.id == transaction.id }
        persist()
    }

    func setBudget(category: String, limit: Decimal, month: Date = Date()) {
        let calendar = Calendar.current
        if let index = budgets.firstIndex(where: { $0.category == category && calendar.isDate($0.month, equalTo: month, toGranularity: .month) }) {
            budgets[index].limit = limit
        } else {
            budgets.append(MonthlyBudget(category: category, limit: limit, month: month))
        }
        persist()
    }

    var spending: Decimal {
        transactions
            .filter { $0.amount < 0 && $0.category != "Card payment" && $0.category != "Internal transfer" }
            .reduce(0) { $0 - $1.amount }
    }

    var income: Decimal {
        transactions
            .filter { $0.amount > 0 && $0.category != "Internal transfer" }
            .reduce(0) { $0 + $1.amount }
    }

    var needsReview: [BankTransaction] {
        transactions.filter { $0.category == "Uncategorised" || $0.pendingSplitDraft != nil }
    }

    func recordImport(fileName: String, count: Int, status: String) {
        imports.insert(ImportRecord(fileName: fileName, transactionCount: count, status: status), at: 0)
        persist()
    }

    private func persist() {
        storage.save(transactions, "transactions.json")
        storage.save(changes, "changes.json")
        storage.save(budgets, "budgets.json")
        storage.save(imports, "imports.json")
    }
}

extension SplitApprovalFailure {
    var explanation: String {
        switch self {
        case .noItems: "add at least one item."
        case .notReviewed: "tick the box to confirm you checked every item."
        case .invalidItem(let index): "item \(index + 1) needs a description and an amount above zero."
        case .uncategorised(let index): "item \(index + 1) needs a category."
        case .unbalanced: "the items do not add up to the bank amount."
        }
    }
}

/// Reads and writes Codable values as JSON files in one folder.
struct JSONFileStorage {
    let folder: URL

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BudgetMacPersonal", isDirectory: true)
    }

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try? data.write(to: folder.appendingPathComponent(name), options: options)
    }

    func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
