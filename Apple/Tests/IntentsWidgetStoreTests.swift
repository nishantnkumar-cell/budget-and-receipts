import BudgetCore
import XCTest
@testable import BudgetReceipts

/// Apple Pay logging, the widgets' figures and Siri's answers.
@MainActor
final class IntentsWidgetStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func date(_ day: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))! }

    func testLoggedApplePayPaymentBecomesTheStatementLineOnImport() throws {
        let store = BudgetStore(folder: folder)
        let logged = store.logPayment(amount: Decimal(string: "45.67")!, merchant: "Tesco", card: "Visa", date: date(2))
        var edited = logged
        edited.category = "Groceries"
        edited.categoryChosen = true
        store.update(edited)
        store.addNote(to: edited, text: "Big shop")
        XCTAssertEqual(store.waitingLoggedPayments.count, 1)

        let csv = "Date,Description,Amount\n03/10/2026,TESCO STORES 2231,-45.67\n"
        store.commitImport(try store.previewImport(text: csv, fileName: "october.csv", mapping: nil), fileName: "october.csv")
        XCTAssertEqual(store.transactions.count, 1, "Logged once, imported once: still one payment")
        let line = try XCTUnwrap(store.transactions.first)
        XCTAssertFalse(line.isLogged)
        XCTAssertEqual(line.category, "Groceries")
        XCTAssertEqual(store.notes.first?.transactionID, line.id)
        XCTAssertTrue(store.likelyDuplicates.isEmpty)
        // Importing the statement again adds nothing.
        XCTAssertTrue(try store.previewImport(text: csv, fileName: "october.csv", mapping: nil).newTransactions.isEmpty)
    }

    func testLoggedPaymentCanBeEditedAndDeleted() {
        let store = BudgetStore(folder: folder)
        let logged = store.logPayment(amount: 3, merchant: "", date: date(2))
        XCTAssertEqual(logged.merchant, "Apple Pay")
        XCTAssertEqual(logged.amount, -3)
        store.delete(logged)
        XCTAssertTrue(BudgetStore(folder: folder).transactions.isEmpty)
    }

    func testCardNameFindsTheAccount() {
        let store = BudgetStore(folder: folder)
        let account = store.addAccount(name: "Amex Gold", number: "376000001234")
        XCTAssertEqual(store.account(forCard: "American Express ••1234")?.id, account.id)
        XCTAssertEqual(store.account(forCard: "Amex Gold")?.id, account.id)
    }

    func testWidgetSnapshotShowsSafeToSpendAndHidesAmountsWhenAsked() {
        let store = BudgetStore(folder: folder)
        let subscriptions = SubscriptionStore(folder: folder)
        let today = Date()
        store.setBudget(category: "Groceries", limit: 300, month: today)
        store.add(BankTransaction(date: today, merchant: "Tesco", amount: -100, category: "Groceries", fingerprint: "t"))
        let snapshot = WidgetBridge.snapshot(store: store, subscriptions: subscriptions, today: today, showAmounts: true)
        XCTAssertEqual(snapshot.leftThisMonth, 200)
        XCTAssertNotNil(snapshot.safeToday)
        let hidden = WidgetBridge.snapshot(store: store, subscriptions: subscriptions, today: today, showAmounts: false)
        XCTAssertFalse(hidden.showsAmounts)
        XCTAssertNil(hidden.safeToday)
        XCTAssertTrue(hidden.bills.isEmpty)
    }

    func testWidgetsFollowTheirOwnSettingNotTheAppLock() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "widget-lock-\(UUID())"))
        XCTAssertTrue(WidgetBridge.showsAmounts(in: defaults))
        defaults.set(true, forKey: "appLockEnabled")
        XCTAssertTrue(WidgetBridge.showsAmounts(in: defaults))
        defaults.set(false, forKey: WidgetBridge.showAmountsKey)
        XCTAssertFalse(WidgetBridge.showsAmounts(in: defaults))
    }

    func testSiriBudgetLeft() {
        let store = BudgetStore(folder: folder)
        let subscriptions = SubscriptionStore(folder: folder)
        XCTAssertTrue(BudgetAnswers.left(category: nil, store: store, subscriptions: subscriptions).contains("Set a budget"))
        store.setBudget(category: "Groceries", limit: 300, month: Date())
        store.add(BankTransaction(date: Date(), merchant: "Tesco", amount: Decimal(string: "-45.50")!, category: "Groceries", fingerprint: "t"))
        XCTAssertEqual(BudgetAnswers.left(category: "groceries", store: store, subscriptions: subscriptions),
                       "\(Decimal(string: "254.50")!.money) left for Groceries this month, of \(Decimal(300).money).")
    }

    func testWidgetLinksOpenPlaces() {
        let navigator = AppNavigator()
        XCTAssertTrue(navigator.open(URL(string: "duobudget://scan")!))
        XCTAssertEqual(navigator.requested, .scan)
        XCTAssertTrue(navigator.open(URL(string: "duobudget://ask")!))
        XCTAssertTrue(navigator.asking)
        XCTAssertFalse(navigator.open(URL(fileURLWithPath: "/tmp/statement.pdf")))
    }
}
