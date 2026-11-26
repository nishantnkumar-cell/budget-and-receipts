import BudgetCore
import XCTest
@testable import TaxCore

final class IndiaBookTests: XCTestCase {
    private let year = TaxYear(startYear: 2026)
    private let after = TaxYear.day(2027, 5, 1)

    func testInterestAndTaxAreReadFromTheBanksWording() {
        func guess(_ text: String, _ amount: Decimal) -> IndiaEntry.Kind { IndiaEntry.guess(narration: text, amount: amount) }
        XCTAssertEqual(guess("XXXXXXXX8765:Int.Pd:31-03-2026 to 29-06-2026", 10), .interest)
        XCTAssertEqual(guess("CREDIT INTEREST--", 10), .interest)
        XCTAssertEqual(guess("TDS ON INTEREST", -3), .taxDeducted)
        XCTAssertEqual(guess("UPI/FRIEND/interest free loan", 10), .other)
        XCTAssertEqual(guess("UPI/INTERNET BILL", -10), .other)
        XCTAssertEqual(guess("CREDIT INTEREST", -10), .other)
        XCTAssertEqual(guess("NEFT FROM MR TDSOUZA", -10), .other)
    }

    func testBalanceIsTheDaysClosingLineWhicheverWayTheFileRuns() {
        let sample = IndiaSample.make()
        XCTAssertEqual(sample.balance(of: "india-sample-sbi")?.rupees, 121_340)
        var reversed = sample
        // Newest first, so the ids would count the other way.
        let text = "Date,Narration,Debit,Credit,Balance\n30/06/2026,TDS,360,,121340\n30/06/2026,CREDIT INTEREST,,1200,121700\n"
        reversed.entries = (try? IndiaStatement.read(text: text).entries(for: "india-sample-sbi", existing: []).new) ?? []
        XCTAssertEqual(reversed.balance(of: "india-sample-sbi")?.rupees, 121_340)
        XCTAssertEqual(sample.balance(of: "india-sample-deposit")?.rupees, 300_000)
        XCTAssertNil(sample.balance(of: "nothing"))
    }

    func testATypedBalanceWinsOnlyWhenNewer() {
        var book = IndiaSample.make()
        var account = book.account("india-sample-sbi")!
        account.statedBalance = 5
        account.statedOn = TaxYear.day(2026, 5, 1)
        book.save(account)
        XCTAssertEqual(book.balance(of: account.id)?.rupees, 121_340)
        account.statedOn = TaxYear.day(2026, 7, 1)
        book.save(account)
        XCTAssertEqual(book.balance(of: account.id)?.rupees, 5)
    }

    func testASheetLeftOpenOnlySavesWhatItChanged() {
        var book = IndiaSample.make()
        let opened = book.account("india-sample-sbi")!
        var elsewhere = opened
        elsewhere.isPrivate = true
        book.save(elsewhere)
        var draft = opened
        draft.nickname = "Savings"
        book.save(draft, editedFrom: opened)
        XCTAssertEqual(book.account(opened.id)?.nickname, "Savings")
        XCTAssertEqual(book.account(opened.id)?.isPrivate, true)
        book.deleteAccount(opened.id)
        book.save(draft, editedFrom: opened)
        XCTAssertNil(book.account(opened.id))
        book.add(try! IndiaStatement.read(text: IndiaSample.sbiStatement), to: opened.id)
        XCTAssertTrue(book.entries(of: opened.id).isEmpty)
    }

    func testReportSplitsAJointAccountAndConvertsAtTheYearsRate() {
        let report = IndiaReport.make(IndiaSample.make(), year: year, person: .me, today: after)
        XCTAssertEqual(report.rows.map(\.account.id), ["india-sample-icici", "india-sample-sbi"])
        XCTAssertEqual(report.interest, 3_650 + 600)
        XCTAssertEqual(report.taxDeducted, 180)
        XCTAssertEqual(report.interestPounds, Decimal(string: "36.96"))
        XCTAssertEqual(report.taxPounds, Decimal(string: "1.57"))
        XCTAssertEqual(report.warnings, [])
        let partner = IndiaReport.make(IndiaSample.make(), year: year, person: .partner, today: after)
        XCTAssertEqual(partner.interest, 600 + 5_250)
    }

    func testReportSaysWhatNeedsChecking() {
        var book = IndiaSample.make()
        book.setRate("2026-27", rupeesPerPound: nil)
        book.entries.removeAll { $0.kind == .taxDeducted }
        book.save(.manual(accountID: "india-sample-icici", date: TaxYear.day(2026, 9, 30), kind: .interest, rupees: 1))
        let report = IndiaReport.make(book, year: year, person: .me, today: TaxYear.day(2026, 10, 1))
        XCTAssertNil(report.interestPounds)
        let all = report.warnings.joined(separator: "\n")
        for expected in ["rupees to a pound", "counted twice", "no tax deducted", "isn't over"] {
            XCTAssertTrue(all.contains(expected), expected)
        }
    }

    func testOnlyTheTaxYearsLinesCount() {
        var book = IndiaSample.make()
        book.save(.manual(accountID: "india-sample-icici", date: TaxYear.day(2026, 4, 5), kind: .interest, rupees: 100))
        book.save(.manual(accountID: "india-sample-icici", date: TaxYear.day(2027, 4, 6), kind: .interest, rupees: 100))
        XCTAssertEqual(IndiaReport.make(book, year: year, person: .me, today: after).interest, 4_250)
    }

    func testAChosenKindReplacesTheGuess() {
        var book = IndiaSample.make()
        var line = book.entries.first { $0.accountID == "india-sample-icici" && $0.kind == .interest }!
        line.chosenKind = .other
        book.save(line)
        XCTAssertEqual(IndiaReport.make(book, year: year, person: .me, today: after).interest, 600)
    }

    func testCSVHasTheLinesAndTotalsAndNoFormulas() {
        var book = IndiaSample.make()
        var line = IndiaEntry.manual(accountID: "india-sample-icici", date: TaxYear.day(2026, 9, 30), kind: .interest, rupees: 1, note: "=HYPERLINK(1)")
        line.id = "manual|x"
        book.save(line)
        let csv = IndiaReport.make(book, year: year, person: .me, today: after).csv(book)
        XCTAssertTrue(csv.contains("'=HYPERLINK(1)"))
        XCTAssertTrue(csv.contains("2026-27,Total,,,,4251,180,36.97,1.57,0,0,0,0,115,"))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").count, 7)
    }

    func testRupeesAreGroupedAsInIndia() {
        XCTAssertEqual(IndiaMoney.format(Decimal(string: "12345678.5")!), "₹1,23,45,678.50")
        XCTAssertEqual(IndiaMoney.format(-1_000), "-₹1,000.00")
        XCTAssertEqual(IndiaMoney.format(999), "₹999.00")
        XCTAssertEqual(IndiaMoney.parse("1,25,000.50"), Decimal(string: "125000.50"))
        XCTAssertNil(IndiaMoney.parse("-5"))
        XCTAssertNil(IndiaMoney.pounds(5, rupeesPerPound: 0))
    }
}
