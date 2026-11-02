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
    /// Scanned receipts whose card payment is not on a statement yet.
    @Published var pendingReceipts: [PendingReceipt] = []
    @Published var accounts: [BankAccount] = []
    /// Show one account's money only. Nil shows every account.
    @Published var accountFilter: UUID?
    /// Accounts found in the statement being previewed, added when it is imported.
    private var proposedAccounts: [BankAccount] = []
    /// The Me / Partner / Together switch. Together shows everything, as before couples.
    @Published var householdView: HouseholdView = .together

    private let storage: JSONFileStorage
    /// Called after every local change is saved, so iCloud sync can send it.
    var didPersist: (() -> Void)?

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
        pendingReceipts = storage.load("pending-receipts.json") ?? []
        accounts = storage.load("accounts.json") ?? []
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
        let inAccount = accountFilter.map { id in transactions.filter { $0.accountID == id } } ?? transactions
        return hasPartner ? ledger.transactions(inAccount, for: householdView) : inAccount
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
    /// - Parameter account: the account the statement is from, when the file doesn't say.
    ///   Account numbers in the file win; unknown numbers become new accounts on import.
    func previewImport(text: String, fileName: String, mapping: CSVColumnMapping?, account: UUID? = nil) throws -> StatementImportResult {
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
        return preview(rows, account: account)
    }

    /// A PDF statement, from the text lines PDFKit read out of it.
    func previewImport(pdfLines lines: [String], account: UUID? = nil) throws -> StatementImportResult {
        let year = Calendar.current.component(.year, from: Date())
        let rows = try PDFStatementParser.parse(lines, fallbackYear: year)
        var result = preview(rows, account: account)
        result.summaryDifference = PDFStatementParser.summaryDifference(lines, rows: rows)
        return result
    }

    private func preview(_ rows: [StatementRow], account: UUID?) -> StatementImportResult {
        proposedAccounts = []
        for number in Set(rows.compactMap(\.accountNumber)).sorted() where BankAccounts.account(forNumber: number, in: accounts) == nil {
            if BankAccounts.account(forNumber: number, in: proposedAccounts) == nil, !BankAccount.lastFour(number).isEmpty {
                proposedAccounts.append(BankAccount(name: "Account", number: number))
            }
        }
        let known = accounts + proposedAccounts
        var result = StatementImporter.prepare(rows, existing: transactions, account: account) { BankAccounts.account(forNumber: $0, in: known)?.id }
        // Fill in categories from your past choices and well-known shops; you can change any of them.
        result.newTransactions = categoriser.categorise(result.newTransactions)
        // A partner's or joint account makes its spending theirs or shared.
        result.newTransactions = BankAccounts.applyOwners(result.newTransactions, accounts: known)
        return result
    }

    /// Suggests categories on the device, learning from the ones you already chose.
    var categoriser: Categoriser { Categoriser(history: transactions) }

    /// Adds the new transactions from a previewed import and records it in the import history.
    func commitImport(_ result: StatementImportResult, fileName: String) {
        let used = Set(result.newTransactions.compactMap(\.accountID))
        accounts += proposedAccounts.filter { used.contains($0.id) }
        proposedAccounts = []
        transactions.insert(contentsOf: result.newTransactions, at: 0)
        transactions.sort { $0.date > $1.date }
        let status = result.duplicates.isEmpty ? "Imported" : "Imported, \(result.duplicates.count) already present"
        imports.insert(ImportRecord(fileName: fileName, transactionCount: result.newTransactions.count, status: status), at: 0)
        let matched = matchPendingReceipts()
        persist()
        self.status = "Imported \(result.newTransactions.count) transactions from \(fileName)."
            + (matched > 0 ? " Matched \(matched) waiting receipt\(matched == 1 ? "" : "s"); check them in the Inbox." : "")
    }

    // MARK: Accounts

    @discardableResult
    func addAccount(name: String, number: String = "") -> BankAccount {
        let account = BankAccount(name: name, number: number)
        accounts.append(account)
        persist()
        return account
    }

    func updateAccount(_ account: BankAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        persist()
    }

    /// Removes an account. Its transactions stay, without an account.
    func deleteAccount(_ account: BankAccount) {
        accounts.removeAll { $0.id == account.id }
        for index in transactions.indices where transactions[index].accountID == account.id {
            transactions[index].accountID = nil
        }
        if accountFilter == account.id { accountFilter = nil }
        persist()
    }

    func account(_ id: UUID?) -> BankAccount? { id.flatMap { id in accounts.first { $0.id == id } } }

    /// This month's spending per account, largest first. Transactions without an account come last.
    var spendingByAccount: [(account: BankAccount?, spent: Decimal)] {
        BankAccounts.spendingByAccount(transactions, month: selectedMonth, calculator: calculator)
            .map { (account: account($0.key), spent: $0.value) }
            .sorted { ($0.account == nil ? 1 : 0, -$0.spent) < ($1.account == nil ? 1 : 0, -$1.spent) }
    }

    // MARK: Waiting receipts

    /// Keeps a scanned receipt until its card payment shows up on a statement.
    func savePending(_ editor: ReceiptDraftEditor) {
        pendingReceipts.append(PendingReceipt(editor: editor))
        persist()
        status = "Receipt saved. It will be matched when its payment is imported."
    }

    /// Attaches a waiting receipt to a payment. It still waits in the Inbox for approval.
    func attachPending(_ receipt: PendingReceipt, to transaction: BankTransaction) {
        pendingReceipts.removeAll { $0.id == receipt.id }
        saveDraft(receipt.editor.makeDraft(reviewed: false), for: transaction)
    }

    func deletePending(_ receipt: PendingReceipt) {
        pendingReceipts.removeAll { $0.id == receipt.id }
        persist()
    }

    /// Attaches waiting receipts to payments when the match is certain. Returns how many.
    @discardableResult
    func matchPendingReceipts() -> Int {
        let accounts = accounts
        let pairs = ReceiptMatcher.autoMatch(pendingReceipts, in: transactions) { BankAccounts.account(forReceiptText: $0.editor.rawText, in: accounts)?.id }
        for pair in pairs {
            guard let receipt = pendingReceipts.first(where: { $0.id == pair.receipt }),
                  let index = transactions.firstIndex(where: { $0.id == pair.transaction }) else { continue }
            transactions[index].pendingSplitDraft = receipt.editor.makeDraft(reviewed: false)
            pendingReceipts.removeAll { $0.id == receipt.id }
        }
        if !pairs.isEmpty { persist() }
        return pairs.count
    }

    var needsReview: [BankTransaction] {
        transactions.filter { $0.category == "Uncategorised" || $0.pendingSplitDraft != nil }
    }

    private func persist() {
        writeFiles()
        didPersist?()
    }

    private func writeFiles() {
        storage.save(transactions, "transactions.json")
        storage.save(changes, "changes.json")
        storage.save(budgets, "budgets.json")
        storage.save(imports, "imports.json")
        storage.save(couple, "couple.json")
        storage.save(settlements, "settlements.json")
        storage.save(pendingReceipts, "pending-receipts.json")
        storage.save(accounts, "accounts.json")
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

// MARK: - iCloud sync

extension BudgetStore: SyncSource {
    /// Every item as an iCloud record. An item is private when marked, or when its account is.
    func syncRecords() -> [SyncRecord] {
        let privateAccounts = Set(accounts.filter { $0.isPrivate == true }.map(\.id))
        func isPrivate(_ transaction: BankTransaction) -> Bool {
            transaction.isPrivate == true || transaction.accountID.map(privateAccounts.contains) == true
        }
        return SyncRecord.records(transactions, collection: "transactions", id: \.fingerprint, isPrivate: isPrivate)
            + SyncRecord.records(changes, collection: "changes", id: \.id.uuidString)
            + SyncRecord.records(budgets, collection: "budgets", id: \.id.uuidString)
            + SyncRecord.records(imports, collection: "imports", id: \.id.uuidString)
            + SyncRecord.records([couple], collection: "couple", id: { _ in "settings" })
            + SyncRecord.records(settlements, collection: "settlements", id: \.id.uuidString)
            + SyncRecord.records(pendingReceipts, collection: "pendingReceipts", id: \.id.uuidString, isPrivate: { $0.isPrivate == true })
            + SyncRecord.records(accounts, collection: "accounts", id: \.id.uuidString, isPrivate: { $0.isPrivate == true })
            + imageRecords(privateTransactions: transactions.filter(isPrivate))
    }

    /// Receipt photos travel as files. A photo is private when only private items use it.
    private func imageRecords(privateTransactions: [BankTransaction]) -> [SyncRecord] {
        let images = ReceiptImageStore(dataFolder: storage.folder)
        var used: [String: Bool] = [:]
        func use(_ path: String?, _ isPrivate: Bool) {
            guard let path, !path.isEmpty else { return }
            let name = (path as NSString).lastPathComponent
            used[name] = (used[name] ?? true) && isPrivate
        }
        let privateIDs = Set(privateTransactions.map(\.id))
        for transaction in transactions {
            use(transaction.pendingSplitDraft?.receipt.imagePath, privateIDs.contains(transaction.id))
        }
        for receipt in pendingReceipts { use(receipt.editor.imagePath, receipt.isPrivate == true) }
        return used.compactMap { name, isPrivate in
            guard images.url(for: name) != nil else { return nil }
            return SyncRecord(collection: "images", id: name, payload: Data(), isPrivate: isPrivate, fileName: name)
        }
    }

    var imagesFolder: URL { ReceiptImageStore(dataFolder: storage.folder).folder }

    /// Applies changes from your other devices. Saved to disk, not sent back.
    func applySync(saves: [SyncRecord], deletes: Set<String>) {
        transactions = SyncMerge.apply(saves: saves, deletes: deletes, to: transactions, collection: "transactions", id: \.fingerprint)
            .sorted { $0.date > $1.date }
        changes = SyncMerge.apply(saves: saves, deletes: deletes, to: changes, collection: "changes", id: \.id.uuidString)
        budgets = SyncMerge.apply(saves: saves, deletes: deletes, to: budgets, collection: "budgets", id: \.id.uuidString)
        imports = SyncMerge.apply(saves: saves, deletes: deletes, to: imports, collection: "imports", id: \.id.uuidString)
        couple = SyncMerge.apply(saves: saves, deletes: [], to: [couple], collection: "couple", id: { _ in "settings" }).last ?? couple
        settlements = SyncMerge.apply(saves: saves, deletes: deletes, to: settlements, collection: "settlements", id: \.id.uuidString)
        pendingReceipts = SyncMerge.apply(saves: saves, deletes: deletes, to: pendingReceipts, collection: "pendingReceipts", id: \.id.uuidString)
        accounts = SyncMerge.apply(saves: saves, deletes: deletes, to: accounts, collection: "accounts", id: \.id.uuidString)
        writeFiles()
    }
}

