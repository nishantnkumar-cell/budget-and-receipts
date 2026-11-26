import BudgetCore
import XCTest
@testable import TaxCore

final class PropertyLedgerTests: XCTestCase {
    private let year = TaxSample.year
    private let after = TaxYear.day(2026, 11, 1)
    private let day = TaxYear.day(2025, 6, 1)

    private func ledger(_ transactions: [BankTransaction], _ book: PropertyBook) -> PropertyLedger {
        PropertyLedger.build(transactions: transactions, book: book, year: year, asOf: after)
    }

    private func blocking(_ result: PropertyLedger) -> [String] { result.issues.filter(\.blocksFiling).map(\.message) }

    private func payment(_ id: String, _ amount: Decimal = -500, merchant: String = "A BUILDER", tags: [String]? = nil,
                         splits: [TransactionSplit] = []) -> BankTransaction {
        var payment = BankTransaction(date: day, merchant: merchant, amount: amount, fingerprint: id, splits: splits)
        payment.tags = tags
        return payment
    }

    private var book: PropertyBook {
        PropertyBook(properties: [RentalProperty(id: "flat", name: "Flat"), RentalProperty(id: "house", name: "House")])
    }

    func testSampleCountsEverythingOnce() {
        let sample = TaxSample.make()
        let result = ledger(sample.transactions, sample.book)
        // Gross rent from the statements only: the net bank receipts aren't added again.
        XCTAssertEqual(result.total("flat", .rent), 28_800)
        XCTAssertEqual(result.total("flat", .professionalFees), 3_456)
        XCTAssertEqual(result.total("flat", .repairs), 630)
        XCTAssertEqual(result.total("flat", .ratesAndInsurance), 570)
        XCTAssertEqual(result.total("flat", .financeCost), 9_600)
        XCTAssertEqual(result.total("flat", .mortgagePayment), 13_800)
        XCTAssertEqual(blocking(result).count, 1)
        XCTAssertTrue(blocking(result)[0].contains("CORNER HARDWARE"))
    }

    func testSampleSplitsHalfEach() {
        let sample = TaxSample.make()
        let result = ledger(sample.transactions, sample.book)
        for person in [Person.me, .partner] {
            let pages = TaxCalculator.pages(.make(person, ledger: result, book: sample.book, year: year))
            XCTAssertEqual(pages.income, 14_400)
            XCTAssertEqual(pages.taxableProfit, 12_072)
            XCTAssertEqual(pages.financeCosts, 4_800)
            XCTAssertTrue(pages.joint)
        }
    }

    func testStatementThatDisagreesWithTheBankBlocks() {
        var sample = TaxSample.make()
        sample.book.statements[0].fees = 300
        XCTAssertTrue(blocking(ledger(sample.transactions, sample.book)).contains { $0.contains("the bank shows") })
    }

    func testUnlinkedStatementBesideBankRentBlocks() {
        var sample = TaxSample.make()
        sample.book.statements[0].bankFingerprint = nil
        sample.book.rules.append(PropertyRule(merchantContains: "LETTINGS", propertyID: "flat", category: .rent))
        XCTAssertTrue(blocking(ledger(sample.transactions, sample.book)).contains { $0.contains("Link them") })
    }

    func testMissingLenderFigureBlocks() {
        var sample = TaxSample.make()
        sample.book.interest = []
        let result = ledger(sample.transactions, sample.book)
        XCTAssertEqual(result.total("flat", .financeCost), 0)
        XCTAssertTrue(blocking(result).contains { $0.contains("interest figure") })
    }

    func testUnequalSharesNeedForm17() {
        var sample = TaxSample.make()
        sample.book.properties[0].myShare = Decimal(1) / 10
        XCTAssertTrue(blocking(ledger(sample.transactions, sample.book)).contains { $0.contains("Form 17") })
        sample.book.properties[0].form17 = true
        XCTAssertFalse(blocking(ledger(sample.transactions, sample.book)).contains { $0.contains("Form 17") })
    }

    func testTaxYearRunsSixthToFifthApril() {
        XCTAssertFalse(year.contains(TaxYear.day(2025, 4, 5)))
        XCTAssertTrue(year.contains(TaxYear.day(2025, 4, 6)))
        XCTAssertTrue(year.contains(TaxYear.day(2026, 4, 5)))
        XCTAssertFalse(year.contains(TaxYear.day(2026, 4, 6)))
        XCTAssertNil(TaxYear("2027-28"))
    }

    func testRefundReducesACostAndDuplicatesCountOnce() {
        var book = book
        book.rules = [PropertyRule(merchantContains: "builder", propertyID: "flat", category: .repairs)]
        let paid = payment("a")
        XCTAssertEqual(ledger([paid, paid, payment("b", 100)], book).total("flat", .repairs), 400)
    }

    func testOnlyChosenPartsOfASplitPaymentCount() {
        let repair = TransactionSplit(label: "Boiler", category: "Housing", amount: 300)
        let own = TransactionSplit(label: "Groceries", category: "Groceries", amount: 200)
        let split = payment("s", splits: [repair, own])
        var book = book
        XCTAssertEqual(PaymentClassifier.classify(split, book: book), .notProperty)
        book.assign(part: repair.id, of: split, to: ("flat", .repairs))
        let result = ledger([split], book)
        XCTAssertEqual(result.total("flat", .repairs), 300)
        XCTAssertEqual(result.lines.count, 1)
        book.assign(part: repair.id, of: split, to: nil)
        XCTAssertTrue(book.assignments.isEmpty)
    }

    func testARuleOrWholeChoiceOnASplitPaymentNeedsALook() {
        let part = TransactionSplit(label: "Part", category: "Housing", amount: 500)
        let split = payment("s", splits: [part])
        var ruled = book
        ruled.rules = [PropertyRule(merchantContains: "BUILDER", propertyID: "flat", category: .repairs)]
        var chosen = book
        chosen.assign(payment("s"), to: "flat", as: .repairs)
        for book in [ruled, chosen] {
            let result = ledger([split], book)
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertTrue(blocking(result).contains { $0.contains("is split") })
        }
        ruled.exclude(split)
        XCTAssertFalse(blocking(ledger([split], ruled)).contains { $0.contains("is split") })
    }

    func testAChoiceWhosePaymentOrPartHasGoneIsNoticed() {
        let part = TransactionSplit(label: "Part", category: "Housing", amount: 500)
        var book = book
        book.assign(payment("gone"), to: "flat", as: .repairs)
        book.assign(part: part.id, of: payment("s", splits: [part]), to: ("flat", .repairs))
        let changed = payment("s", splits: [TransactionSplit(label: "New", category: "Housing", amount: 500)])
        let messages = blocking(ledger([changed], book))
        XCTAssertTrue(messages.contains { $0.contains("no longer there") })
        XCTAssertTrue(messages.contains { $0.contains("split changed") })
        XCTAssertEqual(PropertyLedger.lostAssignments(transactions: [changed], book: book).count, 2)
    }

    func testChoicesFollowALoggedPaymentToItsStatementLine() {
        var book = book
        book.assign(payment("logged"), to: "flat", as: .repairs)
        book.statements = [AgentStatement(id: "s", propertyID: "flat", date: day, grossRent: 10, bankFingerprint: "logged")]
        book.replacePayment("logged", with: "line")
        XCTAssertEqual(book.assignments.map(\.fingerprint), ["line"])
        XCTAssertEqual(book.statements[0].bankFingerprint, "line")
    }

    func testAForeignAmountWaitingForItsStatementBlocks() {
        var abroad = payment("abroad")
        abroad.loggedCurrency = "INR"
        var book = book
        book.assign(abroad, to: "flat", as: .repairs)
        let result = ledger([abroad], book)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertTrue(blocking(result).contains { $0.contains("INR") })
    }

    func testSamePayEnteredTwiceIsPointedOut() {
        var sample = TaxSample.make()
        var copy = sample.book.pay[0]
        copy.id = "copy"
        sample.book.pay.append(copy)
        XCTAssertTrue(ledger(sample.transactions, sample.book).issues.contains { $0.message.contains("entered twice for you") })
    }

    func testNewRuleWinsOverBroaderOnesAndReplacesItself() {
        var book = book
        book.rules = [PropertyRule(merchantContains: "BUILDER", propertyID: "house", category: .otherExpense, added: 5)]
        let paid = payment("a")
        book.assign(paid, to: "flat", as: .capital)
        book.addRule(from: paid, to: "flat", as: .repairs)
        book.addRule(from: paid, to: "flat", as: .repairs)
        XCTAssertEqual(book.rules.count, 2)
        XCTAssertTrue(book.assignments.isEmpty)
        XCTAssertEqual(PaymentClassifier.classify(paid, book: book), .assigned(propertyID: "flat", category: .repairs, source: .byRule))
    }

    func testExcludingBeatsARuleOrATag() {
        var book = book
        book.rules = [PropertyRule(merchantContains: "BUILDER", propertyID: "flat", category: .repairs)]
        let ruled = payment("a")
        let tagged = payment("b", merchant: "SHOP", tags: ["property: house"])
        book.exclude(ruled)
        book.exclude(tagged)
        XCTAssertEqual(PaymentClassifier.classify(ruled, book: book), .assigned(propertyID: "flat", category: .ignore, source: .byHand))
        XCTAssertEqual(PaymentClassifier.classify(tagged, book: book), .assigned(propertyID: "house", category: .ignore, source: .byHand))
    }

    func testRemovingAPropertyRemovesItsEntries() {
        var book = TaxSample.make().book
        book.removeProperty("flat")
        XCTAssertTrue(book.rules.isEmpty && book.assignments.isEmpty && book.statements.isEmpty && book.interest.isEmpty)
        XCTAssertEqual(book.pay.count, 2)
    }

    func testLateOrMissingHistoryBlocks() {
        let late = BankTransaction(date: TaxYear.day(2025, 6, 5), merchant: "X", amount: -1, fingerprint: "x")
        let messages = blocking(ledger([late], book))
        XCTAssertTrue(messages.contains { $0.contains("start on 5 Jun 2025") })
        XCTAssertTrue(messages.contains { $0.contains("stop on 5 Jun 2025") })
        let empty = ledger([], book)
        XCTAssertTrue(blocking(empty).contains { $0.contains("no payments in 2025-26") })
        XCTAssertEqual(empty.issues.filter { $0.message.contains("No pay is entered") }.count, 2)
    }
}
