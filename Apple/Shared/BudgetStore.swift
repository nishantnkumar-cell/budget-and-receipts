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
    /// Category rules, in the order they're tried: your own first, then the starter set.
    @Published var rules: [CategoryRule] = []
    /// Things you're saving up for, on your own or together.
    @Published var goals: [SavingsGoal] = []
    /// Holidays and trips, with their spending, exchange rates and card fees.
    @Published var trips: [Trip] = []
    /// Return-by dates and warranties on things bought.
    @Published var covers: [ProductCover] = []
    /// Built-in categories you've renamed, recoloured or deleted, and your own categories.
    /// Settings › Categories. Every change here moves payments, budgets and rules along.
    @Published private(set) var categories: [CategoryDefinition] = [] {
        didSet { FinanceCategories.catalog = CategoryCatalog(saved: categories) }
    }
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
        loadAll()
    }

    /// True when the files couldn't be opened yet (the device was locked). Nothing is saved
    /// or synced until they're read, so locked files are never overwritten with nothing.
    private(set) var isWaitingForFiles = false

    /// Reads the files again once the device is unlocked. Returns true when that worked.
    @discardableResult
    func reloadIfWaiting() -> Bool {
        guard isWaitingForFiles else { return true }
        loadAll()
        return !isWaitingForFiles
    }

    private func loadAll() {
        isWaitingForFiles = false
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
        rules = Self.withNewStarterRules(loadOrSetAside("rules.json") ?? [])
        categories = loadOrSetAside("categories.json") ?? []
        goals = loadOrSetAside("goals.json") ?? []
        trips = loadOrSetAside("trips.json") ?? []
        covers = loadOrSetAside("covers.json") ?? []
        // Open on a month that has payments: statements usually end before today.
        if selectedMonthIsEmpty, let latest = latestPaymentDate { selectedMonth = latest }
        if !isWaitingForFiles {
            normaliseCategories()
            removeOldSharedCopies()
            recheckBillPayments()
            assignOwnersFromHolders()
            markTransfers()
            readForeignAmounts()
        }
    }

    // MARK: Savings goals

    func saveGoal(_ goal: SavingsGoal) {
        if let index = goals.firstIndex(where: { $0.id == goal.id }) { goals[index] = goal } else { goals.append(goal) }
        persist()
    }

    func deleteGoal(_ goal: SavingsGoal) {
        goals.removeAll { $0.id == goal.id }
        persist()
    }

    /// Money put into (or, negative, taken out of) a goal.
    func addContribution(_ contribution: SavingsGoal.Contribution, to goal: SavingsGoal) {
        guard let index = goals.firstIndex(where: { $0.id == goal.id }) else { return }
        goals[index].contributions.append(contribution)
        persist()
    }

    /// Goals for the Me / Partner / Together switch: yours or shared ones on Me, and so on.
    var viewGoals: [SavingsGoal] {
        guard hasPartner else { return goals }
        return goals.filter { goal in
            switch householdView {
            case .together: true
            case .me: (goal.owner ?? .shared) != .partner
            case .partner: (goal.owner ?? .shared) != .mine
            }
        }
    }

    // MARK: Reimbursements

    /// Marks a payment as being paid back, or (nil) not any more. A linked repayment credit
    /// counts as income again once the mark is taken off.
    func setReimbursement(_ reimbursement: Reimbursement?, for transaction: BankTransaction) {
        guard let index = transactions.firstIndex(where: { $0.id == transaction.id }) else { return }
        let oldRepayment = transactions[index].reimbursement?.repaymentID
        transactions[index].reimbursement = reimbursement
        relinkRepayment(of: transaction.id, from: oldRepayment, to: reimbursement?.repaymentID)
        changes.append(ChangeRecord(date: Date(), transactionID: transaction.id, reason: reimbursement.map { "Reimbursed by \($0.from)" } ?? "No longer reimbursed"))
        persist()
    }

    /// Records the money as paid back, by this credit when it's on a statement.
    func markRepaid(_ transaction: BankTransaction, by credit: BankTransaction?, on date: Date = Date()) {
        guard var reimbursement = transactions.first(where: { $0.id == transaction.id })?.reimbursement else { return }
        reimbursement.receivedOn = credit?.date ?? date
        reimbursement.repaymentID = credit?.id
        setReimbursement(reimbursement, for: transaction)
    }

    var outstandingReimbursements: [Reimbursements.Outstanding] { Reimbursements.outstanding(transactions) }

    // MARK: Trips

    func saveTrip(_ trip: Trip) {
        if let index = trips.firstIndex(where: { $0.id == trip.id }) { trips[index] = trip } else { trips.append(trip) }
        trips.sort { $0.start > $1.start }
        persist()
    }

    /// Removes a trip. Its payments stay, just not on a trip.
    func deleteTrip(_ trip: Trip) {
        trips.removeAll { $0.id == trip.id }
        for index in transactions.indices where transactions[index].tripID == trip.id { transactions[index].tripID = nil }
        persist()
    }

    func summary(of trip: Trip) -> TripLedger.Summary {
        // The saved trip, so payments taken off it since are left out.
        TripLedger.summary(for: trips.first { $0.id == trip.id } ?? trip, in: transactions, calendar: calculator.calendar)
    }

    /// Puts payments on a trip (nil takes them off every trip).
    func setTrip(_ trip: Trip?, for ids: [String]) {
        let ids = Set(ids)
        for index in transactions.indices where ids.contains(transactions[index].id) {
            transactions[index].tripID = trip?.id
        }
        for index in trips.indices {
            trips[index].excluded = (trips[index].excluded ?? []).filter { !ids.contains($0) }
            if trips[index].excluded?.isEmpty == true { trips[index].excluded = nil }
        }
        persist()
    }

    /// Takes one payment off a trip, even one it picked up by its dates.
    func removeFromTrip(_ transaction: BankTransaction, trip: Trip) {
        guard let tripIndex = trips.firstIndex(where: { $0.id == trip.id }) else { return }
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }), transactions[index].tripID == trip.id {
            transactions[index].tripID = nil
        }
        trips[tripIndex].excluded = Array(Set((trips[tripIndex].excluded ?? []) + [transaction.id])).sorted()
        persist()
    }

    /// The trip a payment is on, if any.
    func trip(for transaction: BankTransaction) -> Trip? {
        if let id = transaction.tripID { return trips.first { $0.id == id } }
        return trips.first { TripLedger.payments(for: $0, in: [transaction], calendar: calculator.calendar).isEmpty == false }
    }

    /// Reads amounts in other currencies that statements print beside payments.
    @discardableResult
    func readForeignAmounts() -> Int {
        guard UserDefaults.standard.object(forKey: "readForeignAmounts") as? Bool ?? true else { return 0 }
        let changed = ForeignAmountReader.fill(&transactions, home: AppSettings.currency)
        if !changed.isEmpty { persist() }
        return changed.count
    }

    // MARK: Returns and warranties

    func saveCover(_ cover: ProductCover) {
        if let index = covers.firstIndex(where: { $0.id == cover.id }) { covers[index] = cover } else { covers.append(cover) }
        persist()
    }

    func deleteCover(_ cover: ProductCover) {
        covers.removeAll { $0.id == cover.id }
        persist()
    }

    /// The folder the data lives in, for backups.
    var dataFolder: URL { storage.folder }

    /// Replaces everything with a backup's data, then reloads, so iCloud sync makes the other
    /// devices match. Contracts are reloaded too (they live in the same folder).
    func restore(_ contents: EncryptedBackup.Contents, subscriptions: SubscriptionStore) throws {
        try EncryptedBackup.replace(folder: storage.folder, with: contents)
        unreadableFiles = []
        loadAll()
        subscriptions.reloadAfterRestore()
        persist()
    }

    // MARK: Transfers

    /// Your names as statements write them, for spotting payments between your own accounts.
    var holderNames: [String] {
        var names = accounts.flatMap { $0.holderNames ?? [] }
        if let me = couple.ownerName, me.contains(" ") { names.append(me) }
        if couple.partnerName.contains(" ") { names.append(couple.partnerName) }
        return names
    }

    /// Moves transfers between your own accounts, card bills, top-ups and savings out of
    /// spending and income. Categories you chose yourself stay as they are.
    @discardableResult
    func markTransfers() -> Int {
        recheckTransfers()
        let found = TransferDetector.detect(transactions, accounts: accounts, names: holderNames, calendar: calculator.calendar)
        guard !found.isEmpty else { return 0 }
        for index in transactions.indices {
            guard let change = found[transactions[index].id] else { continue }
            transactions[index].category = change.category
            transactions[index].subcategory = change.subcategory
        }
        persist()
        return found.count
    }

    /// Once: payments starting "BP" were read as BP petrol, but on first direct statements
    /// "BP" means a bill payment ("BP ANDERSON CDA" is rent coming in). They're sorted again.
    private func recheckBillPayments() {
        let key = "bill-payment-recheck-1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let misread = transactions.indices.filter { index in
            let transaction = transactions[index]
            return transaction.categoryChosen != true && transaction.splits.isEmpty && transaction.category == "Transport"
                && Categoriser.matchWords(transaction.merchant).first == "BILLPAY"
        }
        guard !misread.isEmpty else { return }
        for index in misread {
            transactions[index].category = "Uncategorised"
            transactions[index].subcategory = nil
        }
        let ids = Set(misread.map { transactions[$0].id })
        // Re-sort them without learning from their own wrong categories.
        let sorter = Categoriser(history: transactions.filter { !ids.contains($0.id) }, lookedUp: merchantCategories, rules: activeRules, accountNames: accountNames)
        transactions = sorter.categorise(transactions)
        persist()
    }

    /// Once: earlier versions counted real money as transfers ("CARD PAYMENT TO TESCO" as a card
    /// bill, "VODAFONE TOP UP", "FASTER PAYMENT RECEIVED", any equal amounts in two accounts).
    /// Transfers the app chose, not you, are sorted again with today's rules.
    private func recheckTransfers() {
        let key = "transfer-recheck-1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let automatic = transactions.indices.filter { index in
            let transaction = transactions[index]
            return transaction.categoryChosen != true && transaction.splits.isEmpty
                && (transaction.category == "Card payment" || transaction.category == "Internal transfer")
        }
        guard !automatic.isEmpty else { return }
        for index in automatic {
            transactions[index].category = "Uncategorised"
            transactions[index].subcategory = nil
        }
        let ids = Set(automatic.map { transactions[$0].id })
        // Re-sort them without learning from their own old categories; real transfers come back
        // from the rules and the transfer check that runs next.
        let sorter = Categoriser(history: transactions.filter { !ids.contains($0.id) }, lookedUp: merchantCategories, rules: activeRules, accountNames: accountNames)
        transactions = sorter.categorise(transactions)
        persist()
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
        let oldRepayment = transactions[index].reimbursement?.repaymentID
        transactions[index] = transaction
        relinkRepayment(of: transaction.id, from: oldRepayment, to: transaction.reimbursement?.repaymentID)
        persist()
    }

    // MARK: Logged payments (Shortcuts and Siri)

    /// Adds a payment logged from Shortcuts or Siri, e.g. an Apple Pay tap. It's matched to the
    /// statement line when the statement is imported, so it never shows twice.
    @discardableResult
    func logPayment(amount: Decimal, currency: String? = nil, merchant: String, card: String? = nil, date: Date = Date()) -> BankTransaction {
        var payment = BankTransaction.logged(amount: amount, merchant: merchant, card: card, date: date, accountID: card.flatMap(account(forCard:))?.id)
        if let currency, currency.uppercased() != AppSettings.currency.uppercased() {
            // Paid abroad: the amount is in that currency; the statement brings the real cost.
            payment.loggedCurrency = currency.uppercased()
            payment.foreign = ForeignAmount(amount: abs(amount), currency: currency)
            payment.description += " (\(abs(amount).formatted(.currency(code: currency))))"
        }
        let sorter = Categoriser(history: transactions, lookedUp: merchantCategories, rules: activeRules, accountNames: accountNames)
        payment = sorter.categorise([payment])[0]
        transactions.insert(payment, at: 0)
        transactions.sort { $0.date > $1.date }
        persist()
        return payment
    }

    /// The account a Wallet card name points to: by its last four digits, else by name.
    func account(forCard card: String) -> BankAccount? {
        let digits = String(card.filter(\.isNumber).suffix(4))
        if digits.count == 4, let match = accounts.first(where: { BankAccount.lastFour($0.number) == digits }) { return match }
        let words = card.lowercased()
        return accounts.first { !$0.label.isEmpty && (words.contains($0.label.lowercased()) || $0.label.lowercased().contains(words)) }
    }

    /// Joins logged payments to the statement lines that brought the same payment in.
    @discardableResult
    func reconcileLoggedPayments() -> Int {
        let matches = LoggedPaymentMatcher.match(transactions, calendar: calculator.calendar)
        guard !matches.isEmpty else { return 0 }
        for match in matches {
            guard let loggedIndex = transactions.firstIndex(where: { $0.id == match.logged }),
                  let lineIndex = transactions.firstIndex(where: { $0.id == match.statement }) else { continue }
            let logged = transactions[loggedIndex]
            transactions[lineIndex] = LoggedPaymentMatcher.merged(statement: transactions[lineIndex], logged: logged)
            for index in notes.indices where notes[index].transactionID == logged.id { notes[index].transactionID = match.statement }
            for index in transactions.indices where transactions[index].repays == logged.id { transactions[index].repays = match.statement }
            transactions.remove(at: loggedIndex)
        }
        persist()
        return matches.count
    }

    /// Logged payments still waiting for their statement line.
    var waitingLoggedPayments: [BankTransaction] { transactions.filter(\.isLogged) }

    func delete(_ transaction: BankTransaction) {
        transactions.removeAll { $0.id == transaction.id }
        relinkRepayment(of: transaction.id, from: transaction.reimbursement?.repaymentID, to: nil)
        // A deleted repayment no longer pays anything back.
        for index in transactions.indices where transactions[index].reimbursement?.repaymentID == transaction.id {
            transactions[index].reimbursement?.repaymentID = nil
        }
        persist()
    }

    /// Keeps the credit that pays a payment back pointing at it, and lets go of an old one.
    private func relinkRepayment(of paymentID: String, from old: String?, to new: String?) {
        guard old != new else { return }
        if let old, let credit = transactions.firstIndex(where: { $0.id == old }), transactions[credit].repays == paymentID {
            transactions[credit].repays = nil
        }
        if let new, let credit = transactions.firstIndex(where: { $0.id == new }) { transactions[credit].repays = paymentID }
    }

    /// Sets a category's limit from `month` onwards. `rollover` carries leftover money into
    /// the next month; nil keeps the current setting.
    func setBudget(category: String, limit: Decimal, month: Date = Date(), rollover: Bool? = nil) {
        let calendar = Calendar.current
        let current = calculator.budget(for: category, in: budgets, month: month)
        if let index = budgets.firstIndex(where: { $0.category == category && calendar.isDate($0.month, equalTo: month, toGranularity: .month) }) {
            budgets[index].limit = limit
            budgets[index].rollover = rollover ?? budgets[index].rollover
            budgets[index].removed = nil
        } else {
            budgets.append(MonthlyBudget(category: category, limit: limit, month: month, rollover: rollover ?? current?.rollover))
        }
        persist()
    }

    /// Takes away a category's limit from `month` on. Earlier months keep theirs; if an earlier
    /// budget would still carry on, a marker ends it here.
    func removeBudget(category: String, month: Date = Date()) {
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: month)?.start ?? month
        budgets.removeAll { $0.category == category && (calendar.dateInterval(of: .month, for: $0.month)?.start ?? $0.month) >= monthStart }
        if calculator.budget(for: category, in: budgets, month: month) != nil {
            budgets.append(MonthlyBudget(category: category, limit: 0, month: monthStart, removed: true))
        }
        persist()
    }

    /// The month the Overview and Budgets screens show.
    @Published var selectedMonth = Date()

    // MARK: What the data covers

    /// The newest payment's date, so screens can say how far the statements go.
    var latestPaymentDate: Date? { transactions.lazy.map(\.date).max() }

    func hasPayments(in month: Date) -> Bool {
        transactions.contains { calculator.isInMonth($0.date, month) }
    }

    /// True when there are payments, but none in the month on screen: figures for it would only
    /// be budgets and averages, not what happened, so screens say so instead.
    var selectedMonthIsEmpty: Bool { !transactions.isEmpty && !hasPayments(in: selectedMonth) }

    /// "Payments up to 22 Oct" when the month on screen holds the newest payment and it's a few
    /// days old: the month isn't complete, so its totals are only so far.
    var coverageNote: String? {
        guard let latest = latestPaymentDate, calculator.isInMonth(latest, selectedMonth),
              Date().timeIntervalSince(latest) > 3 * 86_400 else { return nil }
        return "Payments up to \(latest.formatted(.dateTime.day().month(.abbreviated)))"
    }

    func showLatestMonthWithPayments() {
        if let latest = latestPaymentDate { selectedMonth = latest }
    }

    var calculator: BudgetCalculator { BudgetCalculator(monthStartDay: AppSettings.monthStartDay) }

    var monthReport: MonthlyBudgetReport {
        calculator.report(viewTransactions, budgets: viewBudgets, month: selectedMonth)
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
        let upcoming = ComingUpPlanner().payments(bills(contracts), from: today)
        return SafeToSpend.calculate(report: monthReport, upcomingBills: upcoming, today: today, period: calculator.monthInterval(for: selectedMonth))
    }

    // MARK: Recurring payments

    /// Payments that come round regularly on your statements (direct debits, standing orders,
    /// subscriptions) and aren't already a bill in Plan.
    func spottedBills(besides contracts: [SubscriptionContract]) -> [RecurringPayment] {
        let tracker = SubscriptionTracker()
        return RecurringDetector.detect(viewTransactions, calendar: calculator.calendar).filter { payment in
            let sample = BankTransaction(date: payment.lastDate, merchant: payment.name + " " + payment.key, amount: -payment.amount, fingerprint: "")
            return !contracts.contains { $0.id == payment.id || tracker.matches(transaction: sample, contract: $0) }
        }
    }

    /// Your bills in Plan plus the ones spotted on your statements, for Coming up,
    /// safe-to-spend and the balance forecast.
    func bills(_ contracts: [SubscriptionContract]) -> [SubscriptionContract] {
        contracts + spottedBills(besides: contracts).map { $0.contract(currency: AppSettings.currency) }
    }

    /// The last day an account's statements reach, when that's before the month on screen,
    /// so an account with no newer statement doesn't just say £0.
    func statementsEnd(for accountID: UUID) -> Date? {
        guard let latest = transactions.lazy.filter({ $0.accountID == accountID }).map(\.date).max(),
              latest < calculator.monthInterval(for: selectedMonth).start else { return nil }
        return latest
    }

    /// A warning when this receipt looks like one already saved or attached. Nil when it's new.
    func possibleDuplicate(of editor: ReceiptDraftEditor, excluding pendingID: UUID? = nil) -> String? {
        ReceiptDuplicates.match(editor, pending: pendingReceipts.filter { $0.id != pendingID }, transactions: transactions)
    }

    /// Budgets scaled to the selected side of the household, to compare with `viewTransactions`.
    var viewBudgets: [MonthlyBudget] {
        hasPartner ? ledger.budgets(budgets, for: householdView) : budgets
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
        assignOwnersFromHolders()
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

    /// Undoes a settle-up recorded by mistake.
    func deleteSettlement(_ settlement: Settlement) {
        settlements.removeAll { $0.id == settlement.id }
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
        var rows: [StatementRow]
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
        // Checked before any signs are turned round: the balance moves with the file's own signs.
        let balanceDifference = StatementImporter.balanceDifference(rows)
        let cardSigns = StatementImporter.fixingCardSigns(rows)
        rows = cardSigns.rows
        var result = preview(rows, account: account)
        result.balanceDifference = balanceDifference
        result.signsFlipped = cardSigns.flipped
        return result
    }

    /// A PDF statement, from the text lines PDFKit read out of it.
    func previewImport(pdfLines lines: [String], account: UUID? = nil) throws -> StatementImportResult {
        let year = Calendar.current.component(.year, from: Date())
        let rows = try PDFStatementParser.parse(lines, fallbackYear: year)
        let bank = PDFStatementParser.accountName(in: lines)
        let holders = PDFStatementParser.holderNames(in: lines)
        var result = preview(rows, account: account, bankName: bank, holders: holders)
        result.summaryDifference = PDFStatementParser.summaryDifference(lines, rows: rows)
        result.bankName = bank
        result.holderNames = holders
        return result
    }

    /// Whose account a statement is from, by its holders' names against the names in Settings > Couple.
    /// Nil without a partner: with one person every account is theirs, and nothing is decided
    /// until the partner's name is set.
    func owner(ofHolders holders: [String]) -> MoneyOwner? {
        guard hasPartner, !holders.isEmpty else { return nil }
        return AccountHolders.owner(holders: holders, myName: couple.ownerName, partnerName: couple.partnerName)
    }

    /// Gives accounts with no owner chosen the one their statements' holders show, e.g. after the
    /// partner's name is set, or for statements imported before this was read. Payments already
    /// imported from a partner's account are marked as paid by them. Owners you chose stay.
    @discardableResult
    func assignOwnersFromHolders() -> Int {
        var changed = 0
        for index in accounts.indices where accounts[index].owner == nil {
            guard let owner = owner(ofHolders: accounts[index].holderNames ?? []) else { continue }
            accounts[index].owner = owner
            changed += 1
            guard owner == .partner else { continue }
            let id = accounts[index].id
            for t in transactions.indices where transactions[t].accountID == id && transactions[t].owner == nil && transactions[t].paidBy == nil {
                transactions[t].paidBy = .partner
            }
        }
        if changed > 0 { persist() }
        return changed
    }

    private func preview(_ rows: [StatementRow], account: UUID?, bankName: String? = nil, holders: [String] = []) -> StatementImportResult {
        // The statement's holders say whose account it is, e.g. a statement in your partner's name is theirs.
        let holderOwner = owner(ofHolders: holders)
        proposedAccounts = []
        for number in Set(rows.compactMap(\.accountNumber)).sorted() where BankAccounts.account(forNumber: number, in: accounts) == nil {
            if BankAccounts.account(forNumber: number, in: proposedAccounts) == nil, !BankAccount.lastFour(number).isEmpty {
                // Only the last four digits are kept: enough to recognise the account.
                // Named after the bank on the statement, e.g. "first direct", so it reads well at once.
                var proposed = BankAccount(name: bankName ?? "Account", number: BankAccount.lastFour(number))
                proposed.owner = holderOwner
                proposedAccounts.append(proposed)
            }
        }
        // An account of yours with no owner chosen yet takes the statement's; one you set stays.
        let touched = statementAccounts(rows, account: account)
        let known = (accounts + proposedAccounts).map { candidate in
            var candidate = candidate
            if candidate.owner == nil, touched.contains(candidate.id) { candidate.owner = holderOwner }
            return candidate
        }
        var result = StatementImporter.prepare(rows, existing: transactions, account: account) { BankAccounts.account(forNumber: $0, in: known)?.id }
        // Fill in categories from your past choices and well-known shops; you can change any of them.
        result.newTransactions = categoriser.categorise(result.newTransactions)
        // A partner's or joint account makes its spending theirs or shared.
        result.newTransactions = BankAccounts.applyOwners(result.newTransactions, accounts: known)
        // Lines with no account still follow the statement's holders.
        if let holderOwner, holderOwner != .mine {
            for index in result.newTransactions.indices where result.newTransactions[index].accountID == nil && result.newTransactions[index].owner == nil {
                result.newTransactions[index].owner = holderOwner
                if holderOwner == .partner { result.newTransactions[index].paidBy = .partner }
            }
        }
        result.holderOwner = holderOwner
        return result
    }

    /// The saved accounts a statement is from: those its account numbers match, else the one chosen.
    private func statementAccounts(_ rows: [StatementRow], account: UUID?) -> Set<UUID> {
        var ids = Set(rows.compactMap(\.accountNumber).compactMap { BankAccounts.account(forNumber: $0, in: accounts)?.id })
        if ids.isEmpty, let account { ids.insert(account) }
        return ids
    }

    /// Suggests categories on the device, learning from the ones you already chose.
    var categoriser: Categoriser {
        Categoriser(history: transactions, lookedUp: merchantCategories, rules: activeRules, accountNames: accountNames)
    }

    /// Your rules, then a built-in rule for payments between the account holders, then the rest.
    var activeRules: [CategoryRule] {
        let names = accounts.flatMap { $0.holderNames ?? [] }
        guard let selfTransfers = RulesEngine.selfTransferRule(names: names) else { return rules }
        let firstStarter = rules.firstIndex(where: \.isStarter) ?? rules.endIndex
        var all = rules
        all.insert(selfTransfers, at: firstStarter)
        return all
    }

    /// Account names by id, for rules about an account.
    var accountNames: [UUID: String] { Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    // MARK: Categories

    /// The categories as they are now: built-in ones as you've changed them, plus your own.
    var catalog: CategoryCatalog { CategoryCatalog(saved: categories) }

    /// Moves anything still in an old category or sub-category name to its name now.
    /// Runs before every save and after data arrives, so nothing is left behind.
    @discardableResult
    private func normaliseCategories() -> Bool {
        var normaliser = CategoryNormaliser(catalog: catalog)
        guard !normaliser.isIdentity else { return false }
        var changed = false
        var transactions = self.transactions
        if normaliser.normalise(&transactions) { self.transactions = transactions; changed = true }
        var budgets = self.budgets
        if normaliser.normalise(&budgets, calendar: calculator.calendar) { self.budgets = budgets; changed = true }
        var rules = self.rules
        if normaliser.normalise(&rules) { self.rules = rules; changed = true }
        var lookedUp = self.merchantCategories
        if normaliser.normalise(&lookedUp) { merchantCategories = lookedUp; changed = true }
        var receipts = self.pendingReceipts
        if normaliser.normalise(&receipts) { pendingReceipts = receipts; changed = true }
        var couple = self.couple
        if normaliser.normalise(&couple) { self.couple = couple; changed = true }
        return changed
    }

    /// Changes the categories, then saves. Payments, budgets and rules follow in `persist`.
    /// Returns a message when the change isn't allowed.
    @discardableResult
    func editCategories(_ change: (inout CategoryCatalog) throws -> Void) -> String? {
        var edited = catalog
        do {
            try change(&edited)
        } catch let error as CategoryEditError {
            return error.message
        } catch {
            return error.localizedDescription
        }
        categories = edited.changed
        persist()
        return nil
    }

    /// Payments (or parts of payments) in a category, to say what a deletion will move.
    func paymentCount(in category: String) -> Int {
        transactions.filter { $0.category == category || $0.splits.contains { $0.category == category } }.count
    }

    /// Payments with this sub-category.
    func paymentCount(in category: String, subcategory: String) -> Int {
        transactions.filter { $0.category == category && $0.subcategory == subcategory }.count
    }

    // MARK: Rules

    /// Starter rules this device doesn't have yet (new in an update) join the end of the list.
    /// Starter rules are never deleted, only turned off, so a removed one doesn't come back.
    static func withNewStarterRules(_ saved: [CategoryRule]) -> [CategoryRule] {
        let saved = RulesEngine.refreshingStarterRules(saved)
        let have = Set(saved.map(\.id))
        return saved + RulesEngine.starterRules.filter { !have.contains($0.id) }
    }

    func saveRule(_ rule: CategoryRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            // Your own rules go before the starter set, so they win.
            let firstStarter = rules.firstIndex(where: \.isStarter) ?? rules.endIndex
            rules.insert(rule, at: firstStarter)
        }
        persist()
    }

    /// Your own rules are deleted; a starter rule is turned off instead.
    func deleteRule(_ rule: CategoryRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        if rule.isStarter { rules[index].isEnabled = false } else { rules.remove(at: index) }
        persist()
    }

    func moveRules(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Payments a rule matches.
    func matches(for rule: CategoryRule) -> [BankTransaction] {
        RulesEngine.matching(rule, in: transactions, accountNames: accountNames)
    }

    /// Runs every rule: uncategorised payments get a category, and payments in the right
    /// category get a sub-category. With `overwrite`, rules also change categories you set.
    @discardableResult
    func applyRules(overwrite: Bool = false) -> Int {
        let changed = RulesEngine.apply(activeRules, to: &transactions, accountNames: accountNames, overwrite: overwrite)
        if changed > 0 { persist() }
        return changed
    }

    /// Gives every payment one rule matches that rule's category. Returns how many changed.
    @discardableResult
    func apply(_ rule: CategoryRule) -> Int {
        let changed = RulesEngine.apply([rule], to: &transactions, accountNames: accountNames, overwrite: true)
        if changed > 0 { persist() }
        return changed
    }

    /// Merchants already asked about since the app opened, so automatic runs don't ask again.
    private var triedMerchants = Set<String>()

    /// Payments that still have no category and no receipt.
    var uncategorisedCount: Int {
        transactions.filter { $0.category == "Uncategorised" && $0.splits.isEmpty && $0.amount < 0 }.count
    }

    /// The Inbox's "Categorise with AI" button: asks Apple Intelligence (and Apple Maps, if
    /// allowed) about every shop still without a category, and says why when it can't.
    func categoriseNow() async {
        guard !isCategorising else { return }
        if !AppSettings.onlineCategories, let reason = ReceiptAIService.unavailableReason {
            categorisingResult = reason
            return
        }
        let filled = await categoriseUnknownMerchants(useAI: true, retry: true)
        if filled == 0, categorisingResult == nil {
            categorisingResult = uncategorisedCount == 0
                ? "Every payment already has a category."
                : "No new categories found. You can set them yourself."
        }
    }

    /// Finds categories for merchants nobody has categorised yet (Apple Intelligence, then
    /// Apple Maps if allowed) and fills them in. Runs after imports and when the app opens;
    /// each merchant is asked about once per launch unless `retry`.
    /// Returns how many transactions got a category.
    @discardableResult
    func categoriseUnknownMerchants(useAI: Bool = AppSettings.aiCategories, useMaps: Bool = AppSettings.onlineCategories,
                                    retry: Bool = false,
                                    lookup: (String) async -> MerchantCategory? = { _ in nil }) async -> Int {
        guard useAI || useMaps, !isCategorising, !isWaitingForFiles else { return 0 }
        let merchants = MerchantCategories.unknownMerchants(transactions, known: merchantCategories, categoriser: categoriser)
            .filter { retry || !triedMerchants.contains(Categoriser.merchantKey($0)) }
            .prefix(60)
        guard !merchants.isEmpty else { return 0 }
        isCategorising = true
        categorisingResult = nil
        defer { isCategorising = false }
        for merchant in merchants {
            let found: MerchantCategory?
            if let result = await lookup(merchant) {
                found = result
            } else {
                found = await MerchantCategoryService.category(for: merchant, useAI: useAI, useMaps: useMaps)
            }
            triedMerchants.insert(Categoriser.merchantKey(merchant))
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
        let used = Set(result.newTransactions.compactMap(\.accountID)).union(result.accountForExisting.values)
        accounts += proposedAccounts.filter { used.contains($0.id) }
        proposedAccounts = []
        // Remember who holds the accounts, to recognise payments between you.
        if !result.holderNames.isEmpty {
            let numbers = Set(result.duplicates.compactMap(\.accountNumber).map(BankAccount.lastFour))
            for index in accounts.indices where used.contains(accounts[index].id) || numbers.contains(BankAccount.lastFour(accounts[index].number)) {
                accounts[index].holderNames = Array(Set((accounts[index].holderNames ?? []) + result.holderNames)).sorted()
                // Whose account it is, unless you already chose.
                if accounts[index].owner == nil { accounts[index].owner = result.holderOwner }
            }
        }
        // Payments imported before the account was known now get it.
        for index in transactions.indices where transactions[index].accountID == nil {
            if let account = result.accountForExisting[transactions[index].fingerprint] { transactions[index].accountID = account }
        }
        transactions.insert(contentsOf: result.newTransactions, at: 0)
        transactions.sort { $0.date > $1.date }
        let status = result.duplicates.isEmpty ? "Imported" : "Imported, \(result.duplicates.count) already present"
        imports.insert(ImportRecord(fileName: fileName, transactionCount: result.newTransactions.count, status: status), at: 0)
        let joined = reconcileLoggedPayments()
        let matched = matchPendingReceipts()
        if UserDefaults.standard.object(forKey: "readForeignAmounts") as? Bool ?? true {
            ForeignAmountReader.fill(&transactions, home: AppSettings.currency)
        }
        persist()
        markTransfers()
        self.status = "Imported \(result.newTransactions.count) transactions from \(fileName)."
            + (joined > 0 ? " \(joined) payment\(joined == 1 ? "" : "s") logged with Apple Pay joined their statement line\(joined == 1 ? "" : "s")." : "")
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
            transactions[index].categoryChosen = true
        }
        if !ids.isEmpty { persist() }
        return ids.count
    }

    func setAsides(contracts: [SubscriptionContract]) -> [SetAside] { SetAside.plan(contracts) }

    /// The month just shown, looked back on.
    var monthReview: MonthReview { MonthReview.make(viewTransactions, budgets: viewBudgets, month: selectedMonth, calculator: calculator) }

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
        let allBills = bills(contracts)
        let tracker = SubscriptionTracker()
        return BalanceForecast.make(balance: balance, transactions: transactions, upcomingBills: ComingUpPlanner().payments(allBills, from: now), expectedIncome: expected,
                                    isBill: { payment in allBills.contains { tracker.matches(transaction: payment, contract: $0) } }, now: now)
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
        rules = RulesEngine.starterRules
        categories = []
        goals = []
        trips = []
        covers = []
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

    /// Receipts matched to a payment and waiting for you to approve the split.
    var receiptsToApprove: [BankTransaction] { transactions.filter { $0.pendingSplitDraft != nil } }

    /// Payments entered by hand that a statement has since brought in too: same day, amount
    /// and shop. Each pair is listed once, by the hand-entered one.
    /// Card bills from the last two months of statements whose card isn't imported, so what
    /// was bought on the card is missing from spending.
    var untrackedCardBills: [BankTransaction] {
        guard let latest = latestPaymentDate, let since = calculator.calendar.date(byAdding: .day, value: -60, to: latest) else { return [] }
        return TransferDetector.untrackedCardBills(transactions, accounts: accounts, since: since, calendar: calculator.calendar)
    }

    var likelyDuplicates: [BankTransaction] {
        let imported = transactions.filter { !$0.fingerprint.hasPrefix("manual") && !$0.isLogged }
        return transactions.filter { manual in
            if manual.isLogged {
                // Left waiting because two statement lines could be it: you pick.
                return imported.contains {
                    $0.amount == manual.amount && abs($0.date.timeIntervalSince(manual.date)) < 7 * 86_400
                }
            }
            return manual.fingerprint.hasPrefix("manual") && imported.contains {
                $0.amount == manual.amount && calculator.calendar.isDate($0.date, inSameDayAs: manual.date)
                    && Categoriser.merchantKey($0.merchant) == Categoriser.merchantKey(manual.merchant)
            }
        }
    }

    var needsReview: [BankTransaction] {
        transactions.filter { $0.category == "Uncategorised" || $0.pendingSplitDraft != nil }
    }

    private func persist() {
        guard !isWaitingForFiles else { return }
        normaliseCategories()
        writeFiles()
        didPersist?()
        didChange?()
    }

    /// Called after every save, including changes from iCloud, so the widgets can update.
    var didChange: (() -> Void)?

    /// Loads a file; an unreadable one is set aside and remembered (see `unreadableFiles`).
    private func loadOrSetAside<T: Decodable>(_ name: String) -> T? {
        do {
            return try storage.loadChecked(name)
        } catch JSONFileStorage.LoadError.locked {
            isWaitingForFiles = true
            return nil
        } catch {
            storage.setAside(name)
            unreadableFiles.append(name)
            return nil
        }
    }

    @discardableResult
    private func writeFiles() -> Bool {
        guard !isWaitingForFiles else { return false }
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
            storage.save(rules, "rules.json"),
            storage.save(categories, "categories.json"),
            storage.save(goals, "goals.json"),
            storage.save(trips, "trips.json"),
            storage.save(covers, "covers.json"),
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

    enum LoadError: Error {
        /// The file is there but damaged.
        case unreadable(String)
        /// The file is there but locked away (an iPhone still locked since it restarted, or the
        /// app woken in the background while locked). Not damaged: it's read again later.
        case locked(String)
    }

    /// Nil when the file doesn't exist yet. Throws when it exists but can't be read or decoded:
    /// that must never be mistaken for "no data", or sync would delete everything.
    func loadChecked<T: Decodable>(_ name: String) throws -> T? {
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw LoadError.locked(name) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw LoadError.unreadable(name) }
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
            + SyncRecord.records(rules, collection: "rules", id: \.id.uuidString)
            + SyncRecord.records(categories, collection: "categories", id: \.id)
            + SyncRecord.records(goals, collection: "goals", id: \.id.uuidString, isPrivate: { $0.isPrivate == true })
            + SyncRecord.records(trips, collection: "trips", id: \.id.uuidString, isPrivate: { $0.isPrivate == true })
            + SyncRecord.records(covers, collection: "covers", id: \.id.uuidString, isPrivate: { $0.isPrivate == true })
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
        // A receipt kept for its return or warranty keeps its photo after the split is approved.
        for cover in covers { use(cover.receiptImage, cover.isPrivate == true) }
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
        let merged = merge(saves: saves, deletes: deletes)
        // A payment logged on the phone may meet its statement line imported on the Mac.
        if saves.contains(where: { $0.collection == "transactions" }) { reconcileLoggedPayments() }
        // The other side of a transfer may have just arrived from another device.
        if saves.contains(where: { $0.collection == "transactions" || $0.collection == "accounts" }) { markTransfers() }
        return merged
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
        let names = ["rules": "A category rule", "categories": "A category", "notes": "A comment", "budgets": "A budget", "settlements": "A settle-up", "pendingReceipts": "A waiting receipt", "couple": "Couple settings", "goals": "A savings goal", "trips": "A trip", "covers": "A return or warranty", "imports": "An import record", "changes": "A history entry"]
        return names[record.collection] ?? record.collection
    }

    /// Changes another store received from iCloud (contracts), kept in the same list.
    func noteRecentChanges(_ changes: [RecentChange]) {
        let changes = changes.map { change -> RecentChange in
            var change = change
            // A deletion doesn't say who made it: in a household, it may well be the partner.
            if change.kind == .deleted { change.byPartner = householdRole != .solo }
            return change
        }
        recentChanges = (changes + recentChanges).filter { $0.date > Date().addingTimeInterval(-30 * 86_400) }
        writeFiles()
    }

    /// Takes a change off the list once another store has put it back.
    func forget(_ change: RecentChange) {
        recentChanges.removeAll { $0.id == change.id }
        writeFiles()
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
        rules = Self.withNewStarterRules(SyncMerge.apply(saves: saves, deletes: deletes, to: rules, collection: "rules", id: \.id.uuidString))
        categories = SyncMerge.apply(saves: saves, deletes: deletes, to: categories, collection: "categories", id: \.id)
        goals = SyncMerge.apply(saves: saves, deletes: deletes, to: goals, collection: "goals", id: \.id.uuidString)
        trips = SyncMerge.apply(saves: saves, deletes: deletes, to: trips, collection: "trips", id: \.id.uuidString).sorted { $0.start > $1.start }
        covers = SyncMerge.apply(saves: saves, deletes: deletes, to: covers, collection: "covers", id: \.id.uuidString)
        // A rename or deletion from the other device, or a payment it sent in an old category.
        normaliseCategories()
        defer { didChange?() }
        return writeFiles()
    }
}

