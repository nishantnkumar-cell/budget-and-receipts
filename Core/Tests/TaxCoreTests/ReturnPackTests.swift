import BudgetCore
import XCTest
@testable import TaxCore

/// All figures are made up.
final class ReturnPackTests: XCTestCase {
    private let year = TaxYear(startYear: 2025)
    private let after = TaxYear.day(2026, 11, 26)

    private func pack(_ book: PropertyBook, ledger: PropertyLedger = PropertyLedger(), india: IndiaBook = IndiaBook(),
                      person: Person = .me, today: Date? = nil) -> ReturnPack {
        ReturnPack.make(person, year: year, ledger: ledger, book: book, india: india, today: today ?? after)
    }

    private func values(_ pack: ReturnPack, _ kind: ReturnFormKind) -> [String: ReturnValue] {
        Dictionary(pack.forms.filter { $0.kind == kind }.flatMap(\.entries).map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private func job(_ id: String, _ pay: String, _ tax: String, person: Person = .me) -> TaxPay {
        TaxPay(id: id, person: person, taxYear: "2025-26", employer: "Employer \(id)", taxablePay: Decimal(string: pay)!,
               taxDeducted: Decimal(string: tax)!)
    }

    /// Interest, and tax taken off it, in one account per pair, at 100 rupees to the pound.
    private func india(_ accounts: [(interest: Decimal, tax: Decimal)], rate: Decimal? = 100) -> IndiaBook {
        var book = IndiaBook()
        for (index, line) in accounts.enumerated() {
            let account = IndiaAccount(id: "a\(index)", bank: .sbi, kind: .nro, lastFour: "000\(index)")
            book.save(account)
            book.save(.manual(accountID: account.id, date: TaxYear.day(2025, 6, 30), kind: .interest, rupees: line.interest))
            if line.tax > 0 {
                book.save(.manual(accountID: account.id, date: TaxYear.day(2025, 6, 30), kind: .taxDeducted, rupees: line.tax))
            }
        }
        book.setRate("2025-26", rupeesPerPound: rate)
        return book
    }

    func testEachEmployerGetsAPageAndPayIsRoundedHMRCsWay() {
        let result = pack(PropertyBook(pay: [job("b", "100.90", "20.10"), job("a", "5000", "0"), job("x", "1", "1", person: .partner)]))
        let pages = result.forms.filter { $0.kind == .employment }
        XCTAssertEqual(pages.map(\.detail), ["Employer a", "Employer b"])
        XCTAssertEqual(pages[1].entries.map(\.value), [.pounds(100), .pounds(21), .text("Employer b")])
        XCTAssertEqual(values(result, .main)["SA100.TR2.1"], .tick)
        XCTAssertEqual(values(result, .main)["SA100.TR2.1n"], .count(2))
        XCTAssertNil(values(result, .main)["SA100.TR2.4"])
        XCTAssertTrue(result.isReady)
    }

    func testPropertyBoxesComeFromTheSameFiguresAsTheEstimate() {
        let sample = TaxSample.make()
        let ledger = PropertyLedger.build(transactions: sample.transactions, book: sample.book, year: year)
        let result = pack(sample.book, ledger: ledger)
        let expected = TaxCalculator.pages(.make(.me, ledger: ledger, book: sample.book, year: year))
        let boxes = values(result, .property)
        XCTAssertEqual(boxes["SA105.1"], .count(expected.propertyCount))
        XCTAssertEqual(boxes["SA105.20"], .pounds(NSDecimalNumber(decimal: expected.income).intValue))
        XCTAssertEqual(boxes["SA105.40"], .pounds(NSDecimalNumber(decimal: expected.taxableProfit).intValue))
        XCTAssertNil(boxes["SA105.41"])
        XCTAssertEqual(values(result, .main)["SA100.TR2.4"], .tick)
        // What stops the estimate being relied on stops the forms too.
        XCTAssertEqual(result.problems, ledger.issues.filter(\.blocksFiling).map(\.message))
    }

    func testPensionIsEnteredGrossAndGiftAidAsPaid() {
        var pay = job("a", "1000", "0")
        pay.reliefAtSourcePension = Decimal(string: "100.20")!
        let result = pack(PropertyBook(pay: [pay], figures: [YearFigures(person: .me, taxYear: "2025-26", advancePaid: 50, giftAid: 125)]))
        XCTAssertEqual(values(result, .main)["SA100.TR4.1"], .pounds(101))
        XCTAssertEqual(values(result, .main)["SA100.TR4.5"], .pounds(100))
        XCTAssertTrue(result.checks.contains { $0.contains("Payments on account") })
    }

    func testSmallUntaxedInterestGoesOnTheMainReturn() {
        let result = pack(PropertyBook(), india: india([(150_099, 0), (49_900, 0)]))
        XCTAssertEqual(values(result, .main)["SA100.TR3.3"], .pounds(1_999))
        XCTAssertNotNil(values(result, .main)["SA100.TR7.19"])
        XCTAssertTrue(result.forms.allSatisfy { $0.kind != .foreign })
        XCTAssertTrue(result.checks.contains { $0.contains("isn't in the app's tax estimate") })
    }

    func testTaxedInterestGoesOnTheForeignPagesCappedAtTheTreatyRate() {
        // £1,000 interest with £312 taken off, and £500 untaxed.
        let result = pack(PropertyBook(), india: india([(100_000, 31_200), (50_000, 0)]))
        let boxes = values(result, .foreign)
        XCTAssertEqual(boxes["SA106.A1"], .text("IND"))
        XCTAssertEqual(boxes["SA106.B1"], .pounds(1_000))
        XCTAssertEqual(boxes["SA106.C1"], .pounds(150))
        XCTAssertEqual(boxes["SA106.E1"], .tick)
        XCTAssertEqual(boxes["SA106.F1"], .pounds(1_000))
        XCTAssertEqual(boxes["SA106.F2"], .pounds(500))
        XCTAssertNil(boxes["SA106.C2"])
        XCTAssertNil(boxes["SA106.E2"])
        XCTAssertEqual(boxes["SA106.4"], .pounds(1_500))
        XCTAssertNil(values(result, .main)["SA100.TR3.3"])
        XCTAssertEqual(values(result, .main)["SA100.TR2.5"], .tick)
        XCTAssertTrue(result.checks.contains { $0.contains("£162.00 more than the 15%") })
    }

    func testMoreThanTwoThousandUntaxedUsesTheForeignPagesAndAccountsAreAddedByHowTheyWereTaxed() {
        let large = pack(PropertyBook(), india: india([(200_100, 0)]))
        XCTAssertEqual(values(large, .foreign)["SA106.B1"], .pounds(2_001))
        let many = pack(PropertyBook(), india: india([(100_000, 10_000), (100_000, 10_000), (100_000, 31_200), (100_000, 0), (100_000, 0)]))
        let boxes = values(many, .foreign)
        XCTAssertEqual(boxes["SA106.B1"], .pounds(3_000))
        XCTAssertEqual(boxes["SA106.C1"], .pounds(350))
        XCTAssertEqual(boxes["SA106.B2"], .pounds(2_000))
        XCTAssertNil(boxes["SA106.C2"])
        XCTAssertNil(boxes["SA106.B3"])
    }

    func testTaxRelievedNeverPassesTheTreatyShareOfTheFigureShown() {
        let result = pack(PropertyBook(), india: india([(10_099, 3_181)]))
        XCTAssertEqual(values(result, .foreign)["SA106.B1"], .pounds(100))
        XCTAssertEqual(values(result, .foreign)["SA106.C1"], .pounds(15))
    }

    func testAJobEnteredTwiceBlocks() {
        let twice = pack(PropertyBook(pay: [job("a", "40000", "5486"), job("b", "40000", "5486")]))
        XCTAssertFalse(twice.isReady)
        XCTAssertTrue(twice.problems.contains { $0.contains("same pay and tax") })
        var other = job("b", "100", "1")
        other.employer = " employer A"
        let named = pack(PropertyBook(pay: [job("a", "40000", "5486"), other]))
        XCTAssertFalse(named.isReady)
        XCTAssertTrue(pack(PropertyBook(pay: [job("a", "1", "0"), job("b", "2", "0")])).isReady)
    }

    func testAPartYearPayslipIsntTheYearsPay() {
        var pay = job("a", "20000", "3000")
        pay.payslipDate = TaxYear.day(2025, 9, 30)
        let half = pack(PropertyBook(pay: [pay]))
        XCTAssertFalse(half.isReady)
        XCTAssertTrue(half.problems[0].contains("30 Sep 2025"))
        pay.payslipDate = TaxYear.day(2026, 3, 31)
        XCTAssertTrue(pack(PropertyBook(pay: [pay])).isReady)
    }

    func testAPartnersReturnFromASharedHouseholdIsNeverReady() {
        let book = PropertyBook(pay: [job("a", "1", "0", person: .partner), job("b", "2", "0")])
        func made(_ person: Person, _ shared: Bool) -> ReturnPack {
            ReturnPack.make(person, year: year, ledger: PropertyLedger(), book: book, sharedHousehold: shared, today: after)
        }
        XCTAssertFalse(made(.partner, true).isReady)
        XCTAssertTrue(made(.partner, false).isReady)
        XCTAssertTrue(made(.me, true).isReady)
    }

    func testInterestWithoutARateBlocksAndOtherYearsAreRefused() {
        let result = pack(PropertyBook(), india: india([(100_000, 0)], rate: nil))
        XCTAssertFalse(result.isReady)
        XCTAssertTrue(result.problems.contains { $0.contains("rupees to a pound") })
        let later = ReturnPack.make(.me, year: TaxYear(startYear: 2026), ledger: PropertyLedger(), book: PropertyBook(pay: [job("a", "1", "0")]))
        XCTAssertEqual(later.forms, [])
        XCTAssertFalse(later.isReady)
    }

    func testPaperLatenessIsSaidOnceItsPassed() {
        let book = PropertyBook(pay: [job("a", "1", "0")])
        XCTAssertTrue(pack(book).checks[0].contains("31 October 2026"))
        XCTAssertFalse(pack(book, today: TaxYear.day(2026, 10, 31)).checks.contains { $0.contains("31 October 2026") })
        XCTAssertFalse(pack(PropertyBook()).isReady)
    }

    func testEveryEntryHasAPlaceOnItsFormAndFits() {
        var pay = job("a", "99999999", "9999999")
        pay.reliefAtSourcePension = 5
        let sample = TaxSample.make()
        var book = sample.book
        book.pay.append(pay)
        book.figures.append(YearFigures(person: .me, taxYear: "2025-26", losses: 10, financeCosts: 10, giftAid: 10))
        let ledger = PropertyLedger.build(transactions: sample.transactions, book: book, year: year)
        let packs = [pack(book, ledger: ledger, india: india([(100_000, 1), (100_000, 1), (100_000, 1)])), pack(PropertyBook(), india: india([(1_000, 0)]))]
        for entry in packs.flatMap(\.forms).flatMap(\.entries) {
            guard let place = ReturnLayout.placement(of: entry.id) else { XCTFail("No place for \(entry.id)"); continue }
            if case .text = entry.value, place.cells == 1 { continue }
            XCTAssertNotNil(ReturnLayout.characters(entry.value, cells: place.cells), entry.id)
        }
        // Every property box the app can produce has a place.
        for box in ["1", "3", "20", "24", "25", "27", "28", "29", "36", "38", "39", "40", "41", "43", "44", "45"] {
            XCTAssertNotNil(ReturnLayout.placement(of: "SA105.\(box)"), box)
        }
    }

    func testNumbersFillTheCellsFromTheRight() {
        XCTAssertEqual(ReturnLayout.characters(.pounds(125), cells: 5), [" ", " ", "1", "2", "5"])
        XCTAssertEqual(ReturnLayout.characters(.text("IND"), cells: 3), ["I", "N", "D"])
        XCTAssertNil(ReturnLayout.characters(.pounds(123_456), cells: 5))
    }
}
