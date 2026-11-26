import BudgetCore
import TaxCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class TaxStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let flat = RentalProperty(id: "flat", name: "Flat", myShare: Decimal(string: "0.7")!, form17From: TaxYear.day(2025, 4, 6))

    private func record(_ store: TaxStore, _ key: String) -> SyncRecord? { store.syncRecords().first { $0.key == key } }

    func testChangesAreSavedAndSent() {
        let store = TaxStore(folder: folder)
        var sends = 0
        store.didPersist = { sends += 1 }
        store.change { $0.properties.append(flat) }
        store.change { _ in }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(TaxStore(folder: folder).book.properties, [flat])
        XCTAssertEqual(store.syncRecords().map(\.key), ["taxProperties|flat"])
    }

    func testNothingIsWrittenUntilSomethingIsEntered() {
        let store = TaxStore(folder: folder)
        XCTAssertTrue(store.applySync(saves: [], deletes: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tax-items.json").path))
    }

    func testAPartnerSeesSharesFromTheirOwnSideAndSendsThemBackUnchanged() throws {
        let owner = TaxStore(folder: folder.appendingPathComponent("owner"))
        owner.setHouseholdRole(.owner)
        owner.change { $0.properties.append(flat) }
        let sent = owner.syncRecords()
        let member = TaxStore(folder: folder.appendingPathComponent("member"))
        member.setHouseholdRole(.member)
        XCTAssertTrue(member.applySync(saves: sent, deletes: []))
        XCTAssertEqual(member.book.properties.first?.myShare, Decimal(string: "0.3"))
        XCTAssertEqual(member.syncRecords(), sent)
    }

    func testPayStaysPrivateAndAChoiceFollowsItsPaymentsPrivacy() {
        let store = TaxStore(folder: folder)
        var privacy = ["p": false]
        store.paymentPrivacy = { privacy }
        let payment = BankTransaction(date: Date(), merchant: "Plumber", amount: -10, fingerprint: "p")
        store.change { book in
            book.properties.append(flat)
            book.pay.append(TaxPay(id: "job", person: .me, taxYear: "2025-26", employer: "E", taxablePay: 1, taxDeducted: 0))
            book.assign(payment, to: "flat", as: .repairs)
        }
        XCTAssertEqual(record(store, "taxPay|job")?.isPrivate, true)
        XCTAssertEqual(record(store, "taxPayments|p")?.isPrivate, false)
        privacy["p"] = true
        XCTAssertEqual(record(store, "taxPayments|p")?.isPrivate, true)
    }

    func testMakingAPaymentPrivateAndSharedAgainMovesItsChoice() {
        let budget = BudgetStore(folder: folder)
        let tax = TaxStore(folder: folder)
        tax.paymentPrivacy = { budget.paymentPrivacy }
        budget.didChangePrivacy = { tax.privacyChanged($0) }
        var payment = BankTransaction(date: Date(), merchant: "Plumber", amount: -10, fingerprint: "p")
        budget.add(payment)
        tax.change { book in
            book.properties.append(flat)
            book.assign(payment, to: "flat", as: .repairs)
        }
        for hidden in [true, false] {
            payment.isPrivate = hidden ? true : nil
            budget.update(payment)
            XCTAssertEqual(record(tax, "taxPayments|p")?.isPrivate, hidden)
        }
    }

    func testAPartnerCantChangePayTypedInHere() throws {
        let store = TaxStore(folder: folder)
        store.setHouseholdRole(.owner)
        let mine = TaxPay(id: "job", person: .me, taxYear: "2025-26", employer: "E", taxablePay: 100, taxDeducted: 0, isShared: true)
        store.change { $0.pay.append(mine) }
        var theirs = store.syncRecords()[0]
        var altered = mine
        altered.taxablePay = 1
        theirs.payload = try SyncRecord.encoder().encode(altered)
        theirs.byPartner = true
        XCTAssertTrue(store.applySync(saves: [theirs], deletes: []))
        XCTAssertEqual(store.rejectedKeys([theirs]), ["taxPay|job"])
        XCTAssertEqual(store.book.pay, [mine])
        // The same change from your own other device is taken.
        theirs.byPartner = false
        store.applySync(saves: [theirs], deletes: [])
        XCTAssertEqual(store.book.pay.first?.taxablePay, 1)
    }

    func testAPrivatePayIsNeverTurnedRoundForAPartner() {
        let store = TaxStore(folder: folder)
        store.setHouseholdRole(.member)
        store.change { $0.pay.append(TaxPay(id: "job", person: .me, taxYear: "2025-26", employer: "E", taxablePay: 1, taxDeducted: 0)) }
        let sent = store.syncRecords()[0]
        XCTAssertEqual(try? SyncRecord.decoder().decode(TaxPay.self, from: sent.payload).person, .me)
    }

    func testAnotherDevicesDeletionCanBeRestoredButPayCannot() {
        let store = TaxStore(folder: folder)
        var changes: [RecentChange] = []
        store.didReceiveChanges = { changes += $0 }
        store.change { book in
            book.properties.append(flat)
            book.pay.append(TaxPay(id: "job", person: .partner, taxYear: "2025-26", employer: "E", taxablePay: 1, taxDeducted: 0, isShared: true))
        }
        XCTAssertTrue(store.applySync(saves: [], deletes: ["taxProperties|flat", "taxPay|job"]))
        XCTAssertTrue(store.book.isEmpty)
        XCTAssertEqual(changes.map(\.summary), ["Property Flat"])
        store.restore(changes[0])
        XCTAssertEqual(store.book.properties, [flat])
    }

    func testItemsHeldByAnEarlierVersionAreTakenOver() {
        let earlier = TaxStore(folder: folder.appendingPathComponent("source"))
        earlier.change { $0.properties.append(flat) }
        let held = HeldItemsStore(folder: folder, known: [])
        held.applySync(saves: earlier.syncRecords(), deletes: [])
        let store = TaxStore(folder: folder)
        held.release(to: [store, held])
        XCTAssertEqual(store.book.properties, [flat])
        XCTAssertTrue(held.syncRecords().isEmpty)
    }

    func testChoicesFollowALoggedPaymentWhenItsStatementLineArrives() {
        let budget = BudgetStore(folder: folder)
        let tax = TaxStore(folder: folder)
        budget.didReplacePayment = { old, new in tax.change { $0.replacePayment(old, with: new) } }
        let logged = BankTransaction.logged(amount: Decimal(string: "25.00")!, merchant: "B&Q", date: Date())
        budget.add(logged)
        tax.change { book in
            book.properties.append(flat)
            book.assign(logged, to: "flat", as: .repairs)
        }
        budget.add(BankTransaction(date: Date(), merchant: "B&Q", amount: Decimal(string: "-25.00")!, fingerprint: "line"))
        budget.reconcileLoggedPayments()
        XCTAssertEqual(tax.book.assignments.map(\.fingerprint), ["line"])
    }

    func testRestoringABackupMadeBeforeTaxKeepsTheTaxDetails() throws {
        let budget = BudgetStore(folder: folder)
        let backup = try EncryptedBackup.make(folder: folder, password: "long enough", device: "", appVersion: "")
        let tax = TaxStore(folder: folder)
        tax.change { $0.properties.append(flat) }
        try budget.restore(EncryptedBackup.open(backup, password: "long enough"), subscriptions: SubscriptionStore(folder: folder),
                           tax: tax, india: IndiaStore(folder: folder), held: HeldItemsStore(folder: folder, known: budget.collections))
        XCTAssertEqual(tax.book.properties, [flat])
        XCTAssertEqual(TaxStore(folder: folder).book.properties, [flat])
    }

    func testRestoringABackupWithTaxDetailsReplacesThem() throws {
        let budget = BudgetStore(folder: folder)
        let tax = TaxStore(folder: folder)
        tax.change { $0.properties.append(flat) }
        let backup = try EncryptedBackup.make(folder: folder, password: "long enough", device: "", appVersion: "")
        tax.change { $0.properties.append(RentalProperty(id: "later", name: "Later")) }
        try budget.restore(EncryptedBackup.open(backup, password: "long enough"), subscriptions: SubscriptionStore(folder: folder),
                           tax: tax, india: IndiaStore(folder: folder), held: HeldItemsStore(folder: folder, known: budget.collections))
        XCTAssertEqual(tax.book.properties, [flat])
    }

    func testAPartnersOldCopyNeverReplacesAPrivateChoice() {
        let store = TaxStore(folder: folder)
        store.setHouseholdRole(.owner)
        var privacy = ["p": false]
        store.paymentPrivacy = { privacy }
        let payment = BankTransaction(date: Date(), merchant: "Plumber", amount: -10, fingerprint: "p")
        store.change { book in
            book.properties.append(flat)
            book.assign(payment, to: "flat", as: .repairs)
        }
        var old = record(store, "taxPayments|p")!
        privacy["p"] = true
        store.privacyChanged(["p"])
        store.change { $0.assign(payment, to: "flat", as: .capital) }
        old.byPartner = true
        old.isPrivate = false
        store.applySync(saves: [old], deletes: [])
        XCTAssertEqual(store.rejectedKeys([old]), ["taxPayments|p"])
        XCTAssertEqual(store.book.assignments.map(\.category), [.capital])
    }

    func testSampleFiguresReachTheScreens() {
        let budget = BudgetStore(folder: folder)
        let tax = SampleData.taxStore(for: budget)
        tax.year = TaxSample.year
        let ledger = PropertyLedger.build(transactions: budget.transactions, book: tax.book, year: tax.year, asOf: TaxYear.day(2026, 11, 1))
        let pages = TaxCalculator.pages(.make(.me, ledger: ledger, book: tax.book, year: tax.year))
        XCTAssertEqual(pages.taxableProfit, 12_072)
    }

    func testTheYearOnScreenIsTheOneDueNext() {
        XCTAssertEqual(TaxStore.dueYear(on: TaxYear.day(2026, 11, 26)).description, "2025-26")
        XCTAssertEqual(TaxStore.dueYear(on: TaxYear.day(2027, 2, 1)).description, "2026-27")
        XCTAssertEqual(TaxStore.dueYear(on: TaxYear.day(2030, 1, 1)).description, "2026-27")
    }
}
