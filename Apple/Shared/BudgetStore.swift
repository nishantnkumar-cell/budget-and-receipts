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
    /// True while Apple Intelligence or Apple Maps is finding categories.
    @Published var isCategorising = false
    /// What the last category lookup did, shown briefly.
    @Published var categorisingResult: String?
    /// Categories found for merchants the app didn't know, by merchant key.
    @Published var merchantCategories: [String: MerchantCategory] = [:]
    /// Pensions, investments, property, mortgages and other debts, entered by hand.
    @Published var wealthAccounts: [WealthAccount] = []
    /// Comments and reactions on transactions.
    @Published var notes: [TransactionNote] = []
    /// This device's place in a shared household (set from iCloud sync).
    @Published var householdRole: HouseholdLink.Role = .solo
    /// Items changed or deleted by another device or the partner, kept 30 days to restore.
    @Published var recentChanges: [RecentChange] = []
    /// Arrivals refused last time (not the partner's to change).
    private var lastRejected: Set<String> = []
    /// Every file shared or opened with the app, and what became of it.
    @Published var sharedDocuments: [SharedDocument] = []
    /// What the app just did with shared files, shown once as a confirmation.
    @Published var shareSummary: String?
    /// Show one account's money only. Nil shows every account.
    @Published var accountFilter: UUID?
    /// Accounts found in the statement being previewed, added when it is imported.
    private var proposedAccounts: [BankAccount] = []
    /// The Me / Partner / Together switch. Together shows everything, as before couples.
    @Published var householdView: HouseholdView = .together

    private let storage: JSONFileStorage
    /// Files that existed but couldn't be read at launch. They're kept aside, and sync restores
    /// from iCloud instead of treating the data as deleted.
    private(set) var unreadableFiles: [String] = []
    /// False when the last save couldn't be written.
    private(set) var lastSaveSucceeded = true
    /// Called after every local change is saved, so iCloud sync can send it.
    var didPersist: (() -> Void)?

    /// - Parameter folder: where the JSON files live. Tests pass a temporary folder;
    ///   the app uses Application Support.
    init(folder: URL = JSONFileStorage.defaultFolder) {
        storage = JSONFileStorage(folder: folder)
        transactions = loadOrSetAside("transactions.json") ?? []
        changes = loadOrSetAside("changes.json") ?? []
        budgets = loadOrSetAside("budgets.json") ?? []
        imports = loadOrSetAside("imports.json") ?? []
        couple = loadOrSetAside("couple.json") ?? CoupleSettings()
        settlements = loadOrSetAside("settlements.json") ?? []
        pendingReceipts = loadOrSetAside("pending-receipts.json") ?? []
        let savedAccounts: [BankAccount] = loadOrSetAside("accounts.json") ?? []
        accounts = savedAccounts.map { account in
            var trimmed = account
            trimmed.number = BankAccount.lastFour(account.number)
            return trimmed
        }
        sharedDocuments = loadOrSetAside("shared-documents.json") ?? []
        merchantCategories = loadOrSetAside("merchant-categories.json") ?? [:]
        recentChanges = (loadOrSetAside("recent-changes.json") ?? []).filter { $0.date > Date().addingTimeInterval(-30 * 86_400) }
        wealthAccounts = loadOrSetAside("wealth.json") ?? []
        notes = loadOrSetAside("notes.json") ?? []
        removeOldSharedCopies()
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

    /// Adds a transaction entered by hand (see `NewTransactionView`).
    func add(_ transaction: BankTransaction) {
        transactions.append(transaction)
        transactions.sort { $0.date > $1.date }
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

    var calculator: BudgetCalculator { BudgetCalculator(monthStartDay: AppSettings.monthStartDay) }

    var monthReport: MonthlyBudgetReport {
        calculator.report(viewTransactions, budgets: budgets, month: selectedMonth)
    }

    // MARK: Couples

    /// False for a single person; the Me / Partner / Together switch is hidden then.
    var hasPartner: Bool { !couple.partnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var ledger: CoupleLedger {
        var ledger = CoupleLedger(settings: couple, calculator: calculator)
        ledger.accountOwners = Dictionary(accounts.compactMap { account in account.owner.map { (account.id, $0) } }, uniquingKeysWith: { first, _ in first })
        return ledger
    }

    /// How much can be spent today to stay within this month's budgets, after the bills still
    /// to come. Nil when no budgets are set or another month is showing.
    func safeToSpend(contracts: [SubscriptionContract], today: Date = Date()) -> SafeToSpend? {
        let upcoming = ComingUpPlanner().payments(contracts, from: today)
        return SafeToSpend.calculate(report: monthReport, upcomingBills: upcoming, today: today)
    }

    /// A warning when this receipt looks like one already saved or attached. Nil when it's new.
    func possibleDuplicate(of editor: ReceiptDraftEditor, excluding pendingID: UUID? = nil) -> String? {
        ReceiptDuplicates.match(editor, pending: pendingReceipts.filter { $0.id != pendingID }, transactions: transactions)
    }

    /// Transactions scaled to the selected side of the household.
    var viewTransactions: [BankTransaction] {
        let inAccount = accountFilter.map { id in transactions.filter { $0.accountID == id } } ?? transactions
        return hasPartner ? ledger.transactions(inAccount, for: householdView) : inAccount
    }

    /// Who owes whom across everything recorded so far.
    var coupleBalance: CoupleBalance { ledger.balance(transactions, settlements: settlements) }

    func updateCouple(_ settings: CoupleSettings) {
        // Only the household owner changes the couple settings.
        guard householdRole != .member else { return }
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
                // Only the last four digits are kept: enough to recognise the account.
                proposedAccounts.append(BankAccount(name: "Account", number: BankAccount.lastFour(number)))
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
    var categoriser: Categoriser { Categoriser(history: transactions, lookedUp: merchantCategories) }

    /// Finds categories for merchants nobody has categorised yet (Apple Intelligence, then
    /// Apple Maps if allowed) and fills them in. Each merchant is looked up once.
    /// Returns how many transactions got a category.
    @discardableResult
    func categoriseUnknownMerchants(useAI: Bool = AppSettings.aiCategories, useMaps: Bool = AppSettings.onlineCategories,
                                    lookup: (String) async -> MerchantCategory? = { _ in nil }) async -> Int {
        guard useAI || useMaps else { return 0 }
        let merchants = MerchantCategories.unknownMerchants(transactions, known: merchantCategories, categoriser: categoriser).prefix(60)
        guard !merchants.isEmpty else { return 0 }
        isCategorising = true
        defer { isCategorising = false }
        for merchant in merchants {
            let found: MerchantCategory?
            if let result = await lookup(merchant) {
                found = result
            } else {
                found = await MerchantCategoryService.category(for: merchant, useAI: useAI, useMaps: useMaps)
            }
            if let found { merchantCategories[Categoriser.merchantKey(merchant)] = found }
        }
        let before = transactions.filter { $0.category == "Uncategorised" }.count
        transactions = categoriser.categorise(transactions)
        let filled = before - transactions.filter { $0.category == "Uncategorised" }.count
        categorisingResult = filled == 0
            ? "No new categories found. You can set them yourself."
            : "Categorised \(filled) payment\(filled == 1 ? "" : "s"). Check them in Activity."
        persist()
        return filled
    }

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

    // MARK: Net worth

    func saveWealthAccount(_ account: WealthAccount) {
        if let index = wealthAccounts.firstIndex(where: { $0.id == account.id }) {
            wealthAccounts[index] = account
        } else {
            wealthAccounts.append(account)
        }
        persist()
    }

    func deleteWealthAccount(_ account: WealthAccount) {
        wealthAccounts.removeAll { $0.id == account.id }
        persist()
    }

    /// A new value for an account today (or another date). Debts take the amount owed.
    func recordBalance(_ amount: Decimal, for accountID: UUID, on date: Date = Date()) {
        guard let index = wealthAccounts.firstIndex(where: { $0.id == accountID }) else { return }
        wealthAccounts[index].balances.append(.init(date: date, amount: amount))
        persist()
    }

    var netWorthCalculator: NetWorthCalculator { NetWorthCalculator() }

    /// Net worth for the Me / Partner / Together switch (everything for one person).
    var netWorth: Decimal {
        hasPartner ? netWorthCalculator.total(wealthAccounts, for: householdView, ledger: ledger) : netWorthCalculator.total(wealthAccounts)
    }

    var netWorthTrend: [(month: Date, total: Decimal)] { netWorthCalculator.monthlyTrend(wealthAccounts) }
    var netWorthByGroup: [(group: WealthAccount.Group, amount: Decimal)] { netWorthCalculator.byGroup(wealthAccounts) }
    var netWorthByOwner: [MoneyOwner: Decimal] { netWorthCalculator.byOwner(wealthAccounts) }
    /// Accounts whose latest value is over 30 days old.
    var staleWealthAccounts: [WealthAccount] { wealthAccounts.filter { $0.needsUpdate() } }

    // MARK: Comments, corrections, set-asides, month in review

    func notes(for transaction: BankTransaction) -> [TransactionNote] {
        notes.filter { $0.transactionID == transaction.id }.sorted { $0.date < $1.date }
    }

    /// A comment or reaction from this person on a transaction.
    func addNote(to transaction: BankTransaction, text: String = "", reaction: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || reaction != nil else { return }
        notes.append(TransactionNote(transactionID: transaction.id, author: .me, text: trimmed, reaction: reaction))
        persist()
    }

    func deleteNote(_ note: TransactionNote) {
        notes.removeAll { $0.id == note.id }
        persist()
    }

    /// Other uncategorised payments from the same shop as this one.
    func similarUncategorised(to transaction: BankTransaction) -> [BankTransaction] {
        Categoriser.similarUncategorised(to: transaction, in: transactions)
    }

    /// Gives them all the same category in one go, after a correction. Returns how many.
    @discardableResult
    func applyCategory(_ category: String, toSimilar transaction: BankTransaction) -> Int {
        let ids = Set(similarUncategorised(to: transaction).map(\.id))
        for index in transactions.indices where ids.contains(transactions[index].id) {
            transactions[index].category = category
        }
        if !ids.isEmpty { persist() }
        return ids.count
    }

    func setAsides(contracts: [SubscriptionContract]) -> [SetAside] { SetAside.plan(contracts) }

    /// The month just shown, looked back on.
    var monthReview: MonthReview { MonthReview.make(viewTransactions, budgets: budgets, month: selectedMonth, calculator: calculator) }

    // MARK: Tags, expense reports, balance forecast

    /// Every tag in use, for suggestions.
    var allTags: [String] {
        Array(Set(transactions.flatMap { $0.tags ?? [] })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func setTags(_ tags: [String], for transaction: BankTransaction) {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        transactions[index].tags = cleaned.isEmpty ? nil : cleaned
        persist()
    }

    func expenseReport(from: Date, to: Date, tag: String? = nil) -> ExpenseReport {
        ExpenseReport.make(viewTransactions, from: from, to: to, tag: tag, calculator: calculator)
    }

    /// Where the current accounts are heading by month end. Needs at least one current
    /// account or savings balance under Net worth; nil without one.
    func balanceForecast(contracts: [SubscriptionContract], now: Date = Date()) -> BalanceForecast? {
        let cash = wealthAccounts.filter { $0.kind == .cash }
        guard !cash.isEmpty else { return nil }
        let balance = cash.reduce(Decimal(0)) { $0 + ($1.latest?.amount ?? 0) }
        let calendar = Calendar.current
        // Income seen last month is expected again on the same day this month, unless it's already in.
        var expected: [(date: Date, amount: Decimal)] = []
        if let lastMonth = calendar.date(byAdding: .month, value: -1, to: now) {
            let received = transactions.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) && $0.category == "Income" }
            for income in transactions where calendar.isDate(income.date, equalTo: lastMonth, toGranularity: .month) && income.category == "Income" && income.amount > 0 {
                guard !received.contains(where: { Categoriser.merchantKey($0.merchant) == Categoriser.merchantKey(income.merchant) }),
                      let date = calendar.date(byAdding: .month, value: 1, to: income.date) else { continue }
                expected.append((date, income.amount))
            }
        }
        return BalanceForecast.make(balance: balance, transactions: transactions, upcomingBills: ComingUpPlanner().payments(contracts, from: now), expectedIncome: expected, now: now)
    }

    // MARK: Starting again

    /// Removes every transaction, budget, receipt, account and shared file, here and (through
    /// iCloud sync, as deletions) on your other devices. Settings such as currency are kept.
    func resetAllData() {
        transactions = []
        changes = []
        budgets = []
        imports = []
        couple = CoupleSettings()
        settlements = []
        pendingReceipts = []
        accounts = []
        sharedDocuments = []
        merchantCategories = [:]
        recentChanges = []
        wealthAccounts = []
        notes = []
        accountFilter = nil
        householdView = .together
        for folder in [imagesFolder, sharedFilesFolder] {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        status = "All data removed. Import a statement or add a transaction to start."
        persist()
    }

    // MARK: Shared files

    /// Where copies of shared files are kept, so a file can be read again another way.
    var sharedFilesFolder: URL {
        let folder = storage.folder.appendingPathComponent("Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies of shared files are bank statements and receipts: kept 30 days at most.
    private func removeOldSharedCopies() {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for index in sharedDocuments.indices where sharedDocuments[index].receivedAt < cutoff {
            if let name = sharedDocuments[index].storedFile {
                try? FileManager.default.removeItem(at: sharedFilesFolder.appendingPathComponent(name))
                sharedDocuments[index].storedFile = nil
            }
        }
    }

    /// After a shared statement is imported from its preview: record the result, drop the copy.
    func finishSharedImport(_ document: SharedDocument, result: StatementImportResult) {
        var done = document
        done.outcome = .statement(imported: result.newTransactions.count, alreadyThere: result.duplicates.count, totalsDifference: result.summaryDifference)
        if let name = done.storedFile { try? FileManager.default.removeItem(at: sharedFilesFolder.appendingPathComponent(name)) }
        done.storedFile = nil
        update(done)
    }

    func record(_ document: SharedDocument) {
        sharedDocuments.insert(document, at: 0)
        persist()
    }

    func update(_ document: SharedDocument) {
        guard let index = sharedDocuments.firstIndex(where: { $0.id == document.id }) else { return }
        sharedDocuments[index] = document
        persist()
    }

    /// The shared file a waiting receipt came from, if any.
    func sharedDocument(forReceipt id: UUID) -> SharedDocument? {
        sharedDocuments.first { if case .receipt(let pendingID) = $0.outcome { pendingID == id } else { false } }
    }

    /// Removes a shared file from the list, with its waiting receipt and stored copy.
    /// Payments already imported from a statement stay.
    func deleteSharedDocument(_ document: SharedDocument) {
        if case .receipt(let id) = document.outcome { pendingReceipts.removeAll { $0.id == id } }
        if let name = document.storedFile { try? FileManager.default.removeItem(at: sharedFilesFolder.appendingPathComponent(name)) }
        sharedDocuments.removeAll { $0.id == document.id }
        persist()
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

    /// Loads a file; an unreadable one is set aside and remembered (see `unreadableFiles`).
    private func loadOrSetAside<T: Decodable>(_ name: String) -> T? {
        do {
            return try storage.loadChecked(name)
        } catch {
            storage.setAside(name)
            unreadableFiles.append(name)
            return nil
        }
    }

    @discardableResult
    private func writeFiles() -> Bool {
        let results = [
            storage.save(transactions, "transactions.json"),
            storage.save(changes, "changes.json"),
            storage.save(budgets, "budgets.json"),
            storage.save(imports, "imports.json"),
            storage.save(couple, "couple.json"),
            storage.save(settlements, "settlements.json"),
            storage.save(pendingReceipts, "pending-receipts.json"),
            storage.save(accounts, "accounts.json"),
            storage.save(sharedDocuments, "shared-documents.json"),
            storage.save(merchantCategories, "merchant-categories.json"),
            storage.save(recentChanges, "recent-changes.json"),
            storage.save(wealthAccounts, "wealth.json"),
            storage.save(notes, "notes.json"),
        ]
        lastSaveSucceeded = !results.contains(false)
        return lastSaveSucceeded
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
        // Left out of iCloud device Backup, which isn't end-to-end encrypted unless Advanced
        // Data Protection is on. The encrypted iCloud sync is the backup instead.
        Self.excludeFromBackup(folder)
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// iPhone files stay readable after the first unlock, so changes arriving from iCloud while
    /// the phone is locked can still be saved (they would otherwise fail silently).
    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        [.atomic]
        #endif
    }

    /// Saves a value. Returns false when it couldn't be written, so callers never assume it was.
    @discardableResult
    func save<T: Encodable>(_ value: T, _ name: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return false }
        do {
            try data.write(to: folder.appendingPathComponent(name), options: Self.writeOptions)
            return true
        } catch {
            return false
        }
    }

    enum LoadError: Error { case unreadable(String) }

    /// Nil when the file doesn't exist yet. Throws when it exists but can't be read or decoded:
    /// that must never be mistaken for "no data", or sync would delete everything.
    func loadChecked<T: Decodable>(_ name: String) throws -> T? {
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(T.self, from: data) else {
            throw LoadError.unreadable(name)
        }
        return value
    }

    func load<T: Decodable>(_ name: String) -> T? {
        try? loadChecked(name)
    }

    /// Moves an unreadable file aside so it is kept, never overwritten.
    func setAside(_ name: String) {
        let url = folder.appendingPathComponent(name)
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(name).unreadable-\(stamp)"))
    }
}

// MARK: - iCloud sync

/// An item another device or the partner changed or deleted, kept so it can be put back.
struct RecentChange: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case changed, deleted }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var byPartner: Bool
    var collection: String
    var itemID: String
    /// The item as it was before, as JSON.
    var previous: Data
    var summary: String
}

extension BudgetStore: SyncSource {
    /// Every item as an iCloud record. An item is private when marked, or when its account is.
    /// On a partner's device shared items are turned to the owner's point of view as they go.
    func syncRecords() -> [SyncRecord] {
        let records = localRecords()
        guard householdRole == .member else { return records }
        return records.map { $0.isPrivate ? $0 : HouseholdPerspective.flipped($0) }
    }

    /// The items from this device's own point of view.
    private func localRecords() -> [SyncRecord] {
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
            + SyncRecord.records(wealthAccounts, collection: "wealth", id: \.id.uuidString, isPrivate: { $0.isPrivate == true })
            + SyncRecord.records(notes, collection: "notes", id: \.id.uuidString)
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

    /// Applies changes from your other devices or the partner. Saved to disk, not sent back.
    /// What they change or delete is kept in Recently changed for 30 days. The owner's couple
    /// settings and own accounts can't be changed by the partner: those arrivals are refused.
    @discardableResult
    func applySync(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        var saves = saves
        if householdRole == .member {
            saves = saves.map { $0.isPrivate ? $0 : HouseholdPerspective.flipped($0) }
        }
        lastRejected = []
        if householdRole == .owner {
            for save in saves where save.byPartner {
                let ownersAccount = save.collection == "accounts"
                    && accounts.first(where: { $0.id.uuidString == save.id }).map { ($0.owner ?? .mine) == .mine } == true
                if save.collection == "couple" || ownersAccount { lastRejected.insert(save.key) }
            }
            saves.removeAll { lastRejected.contains($0.key) }
        }
        keepRecentChanges(saves: saves, deletes: deletes)
        return merge(saves: saves, deletes: deletes)
    }

    func rejectedKeys(_ saves: [SyncRecord]) -> Set<String> { lastRejected }

    private func keepRecentChanges(saves: [SyncRecord], deletes: Set<String>) {
        guard !saves.isEmpty || !deletes.isEmpty else { return }
        let before = Dictionary(localRecords().map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [RecentChange] = []
        for key in deletes {
            guard let old = before[key], old.collection != "images" else { continue }
            kept.append(RecentChange(kind: .deleted, byPartner: householdRole != .solo, collection: old.collection, itemID: old.id, previous: old.payload, summary: summary(of: old)))
        }
        for save in saves {
            guard let old = before[save.key], old.collection != "images", old.payload != save.payload else { continue }
            kept.append(RecentChange(kind: .changed, byPartner: save.byPartner, collection: old.collection, itemID: old.id, previous: old.payload, summary: summary(of: old)))
        }
        recentChanges = (kept + recentChanges).filter { $0.date > Date().addingTimeInterval(-30 * 86_400) }
    }

    private func summary(of record: SyncRecord) -> String {
        if record.collection == "transactions", let transaction = try? SyncRecord.decoder().decode(BankTransaction.self, from: record.payload) {
            return "\(transaction.merchant) \(transaction.amount.formatted(.currency(code: AppSettings.currency)))"
        }
        if record.collection == "accounts", let account = try? SyncRecord.decoder().decode(BankAccount.self, from: record.payload) {
            return "Account \(account.label)"
        }
        if record.collection == "wealth", let account = try? SyncRecord.decoder().decode(WealthAccount.self, from: record.payload) {
            return "\(account.kind.title): \(account.name)"
        }
        let names = ["notes": "A comment", "budgets": "A budget", "settlements": "A settle-up", "pendingReceipts": "A waiting receipt", "couple": "Couple settings", "imports": "An import record", "changes": "A history entry"]
        return names[record.collection] ?? record.collection
    }

    /// Puts an item back as it was before the change or deletion, everywhere.
    func restore(_ change: RecentChange) {
        merge(saves: [SyncRecord(collection: change.collection, id: change.itemID, payload: change.previous)], deletes: [])
        recentChanges.removeAll { $0.id == change.id }
        persist()
    }

    @discardableResult
    private func merge(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        transactions = SyncMerge.apply(saves: saves, deletes: deletes, to: transactions, collection: "transactions", id: \.fingerprint)
            .sorted { $0.date > $1.date }
        changes = SyncMerge.apply(saves: saves, deletes: deletes, to: changes, collection: "changes", id: \.id.uuidString)
        budgets = SyncMerge.apply(saves: saves, deletes: deletes, to: budgets, collection: "budgets", id: \.id.uuidString)
        imports = SyncMerge.apply(saves: saves, deletes: deletes, to: imports, collection: "imports", id: \.id.uuidString)
        couple = SyncMerge.apply(saves: saves, deletes: [], to: [couple], collection: "couple", id: { _ in "settings" }).last ?? couple
        settlements = SyncMerge.apply(saves: saves, deletes: deletes, to: settlements, collection: "settlements", id: \.id.uuidString)
        pendingReceipts = SyncMerge.apply(saves: saves, deletes: deletes, to: pendingReceipts, collection: "pendingReceipts", id: \.id.uuidString)
        accounts = SyncMerge.apply(saves: saves, deletes: deletes, to: accounts, collection: "accounts", id: \.id.uuidString)
        wealthAccounts = SyncMerge.apply(saves: saves, deletes: deletes, to: wealthAccounts, collection: "wealth", id: \.id.uuidString)
        notes = SyncMerge.apply(saves: saves, deletes: deletes, to: notes, collection: "notes", id: \.id.uuidString)
        return writeFiles()
    }
}

