import BudgetCore
import SwiftUI

@MainActor
final class BudgetStore: ObservableObject {
    @Published var transactions: [BankTransaction] = []
    @Published var changes: [ChangeRecord] = []
    @Published var budgets: [MonthlyBudget] = []
    @Published var imports: [ImportRecord] = []
    @Published var status = "Import statements or add a transaction."
    @Published var couple: CoupleSettings = CoupleSettings()
    @Published var settlements: [Settlement] = []
    /// The Me / Partner / Together switch. Together shows everything, as before couples.
    @Published var householdView: HouseholdView = .together

    private let storage: JSONFileStorage

    /// - Parameter folder: where the JSON files live. Tests pass a temporary folder;
    ///   the app uses Application Support.
    init(folder: URL = JSONFileStorage.defaultFolder) {
        storage = JSONFileStorage(folder: folder)
        transactions = storage.load("transactions.json") ?? []
        changes = storage.load("changes.json") ?? []
        budgets = storage.load("budgets.json") ?? []
        imports = storage.load("imports.json") ?? []
        couple = storage.load("couple.json") ?? CoupleSettings()
        settlements = storage.load("settlements.json") ?? []
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

    /// Sets a category's limit from `month` onwards. `rollover` carries leftover money into
    /// the next month; nil keeps the current setting.
    func setBudget(category: String, limit: Decimal, month: Date = Date(), rollover: Bool? = nil) {
        let calendar = Calendar.current
        let current = calculator.budget(for: category, in: budgets, month: month)
        if let index = budgets.firstIndex(where: { $0.category == category && calendar.isDate($0.month, equalTo: month, toGranularity: .month) }) {
            budgets[index].limit = limit
            budgets[index].rollover = rollover ?? budgets[index].rollover
        } else {
            budgets.append(MonthlyBudget(category: category, limit: limit, month: month, rollover: rollover ?? current?.rollover))
        }
        persist()
    }

    /// The month the Overview and Budgets screens show.
    @Published var selectedMonth = Date()

    var calculator: BudgetCalculator { BudgetCalculator() }

    var monthReport: MonthlyBudgetReport {
        calculator.report(viewTransactions, budgets: budgets, month: selectedMonth)
    }

    // MARK: Couples

    /// False for a single person; the Me / Partner / Together switch is hidden then.
    var hasPartner: Bool { !couple.partnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var ledger: CoupleLedger { CoupleLedger(settings: couple, calculator: calculator) }

    /// Transactions scaled to the selected side of the household.
    var viewTransactions: [BankTransaction] {
        hasPartner ? ledger.transactions(transactions, for: householdView) : transactions
    }

    /// Who owes whom across everything recorded so far.
    var coupleBalance: CoupleBalance { ledger.balance(transactions, settlements: settlements) }

    func updateCouple(_ settings: CoupleSettings) {
        couple = settings
        if !hasPartner { householdView = .together }
        persist()
    }

    /// Sets whose money a transaction is and who paid. Nil owner goes back to the rules.
    func setOwner(_ owner: MoneyOwner?, paidBy: Person? = nil, for transaction: BankTransaction) {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        transactions[index].owner = owner
        transactions[index].paidBy = paidBy
        changes.append(ChangeRecord(date: Date(), transactionID: transaction.id, reason: "Set whose money to \(owner?.rawValue ?? "automatic")"))
        persist()
    }

    /// Records that whoever owed money has paid it all back.
    func settleUp(date: Date = Date()) {
        let balance = coupleBalance
        guard let debtor = balance.debtor else { return }
        settlements.append(Settlement(date: date, from: debtor, amount: balance.amountOwed))
        status = "Settled up."
        persist()
    }

    var spending: Decimal { monthReport.spending }
    var income: Decimal { monthReport.income }

    func moveMonth(by months: Int) {
        selectedMonth = Calendar.current.date(byAdding: .month, value: months, to: selectedMonth) ?? selectedMonth
    }

    /// Reads a statement file and works out what importing it would add, without changing anything.
    /// CSV files need a column mapping; pass nil to guess it from the header row.
    func previewImport(text: String, fileName: String, mapping: CSVColumnMapping?) throws -> StatementImportResult {
        let rows: [StatementRow]
        switch StatementFormat(fileName: fileName) {
        case .ofx:
            rows = try StatementImporter.parseOFX(text)
        case .qif:
            rows = try StatementImporter.parseQIF(text)
        case .csv:
            let header = CSVReader.firstRecord(text)
            guard let mapping = mapping ?? CSVColumnMapping.guess(header: header) else { throw StatementImportError.missingColumn("date, description or amount") }
            rows = try StatementImporter.parseCSV(text, mapping: mapping)
        }
        var result = StatementImporter.prepare(rows, existing: transactions)
        // Fill in categories from your past choices and well-known shops; you can change any of them.
        result.newTransactions = categoriser.categorise(result.newTransactions)
        return result
    }

    /// Suggests categories on the device, learning from the ones you already chose.
    var categoriser: Categoriser { Categoriser(history: transactions) }

    /// Adds the new transactions from a previewed import and records it in the import history.
    func commitImport(_ result: StatementImportResult, fileName: String) {
        transactions.insert(contentsOf: result.newTransactions, at: 0)
        transactions.sort { $0.date > $1.date }
        let status = result.duplicates.isEmpty ? "Imported" : "Imported, \(result.duplicates.count) already present"
        imports.insert(ImportRecord(fileName: fileName, transactionCount: result.newTransactions.count, status: status), at: 0)
        persist()
        self.status = "Imported \(result.newTransactions.count) transactions from \(fileName)."
    }

    var needsReview: [BankTransaction] {
        transactions.filter { $0.category == "Uncategorised" || $0.pendingSplitDraft != nil }
    }

    private func persist() {
        storage.save(transactions, "transactions.json")
        storage.save(changes, "changes.json")
        storage.save(budgets, "budgets.json")
        storage.save(imports, "imports.json")
        storage.save(couple, "couple.json")
        storage.save(settlements, "settlements.json")
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
