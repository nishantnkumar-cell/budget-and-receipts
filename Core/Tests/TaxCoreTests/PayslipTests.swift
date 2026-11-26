import BudgetCore
import XCTest
@testable import TaxCore

/// All figures are made up.
final class PayslipTests: XCTestCase {
    /// Label above value, as the file's own text lists it.
    static let stacked = """
    Pay Date/ Tax Period
    06/06/2025 / 9
    Salary
    £2,000.00
    Total Taxable Pay
    £2,200.00
    Income Tax
    £300.00
    Total Deductions
    £400.00
    PAYE Net Pay
    £1,800.00
    To Date Figures
    Taxable Pay
    £19,800.00
    Income Tax
    £2,700.00
    """

    /// Columns side by side, as rows read off the page.
    static let rows = """
    Pay Date/ Tax Period 06/06/2025 / 9   To Date Figures
    Salary £2,000.00   Taxable  Pay £19,800.00
    Income Tax £2,700.00 Income Tax £300.00
    Total Taxable Pay £2,200.00 Total Deductions £400.00
    PAYE Net Pay £1,800.00
    """

    func testReadsBothWaysAPayslipsTextCanComeOut() throws {
        for text in [Self.stacked, Self.rows] {
            let slip = try PayslipReader.read(texts: [text])
            XCTAssertEqual(slip.taxablePayToDate, 19_800)
            XCTAssertEqual(slip.taxToDate, 2_700)
            XCTAssertEqual(slip.taxablePay, 2_200)
            XCTAssertEqual(slip.tax, 300)
            XCTAssertEqual(slip.netPay, 1_800)
            XCTAssertEqual(PropertyLedger.day(slip.payDate), "6 Jun 2025")
            XCTAssertTrue(slip.isChecked, "\(slip.warnings)")
            XCTAssertEqual(slip.warnings, [])
        }
    }

    func testFiguresThatDontAgreeAreFlagged() throws {
        let slip = try PayslipReader.read(texts: [Self.stacked.replacingOccurrences(of: "£1,800.00", with: "£1,700.00")])
        XCTAssertFalse(slip.isChecked)
        XCTAssertFalse(slip.warnings.isEmpty)
    }

    func testMissingFiguresToDateAreNeverGuessed() throws {
        let text = String(Self.stacked.prefix(upTo: Self.stacked.range(of: "To Date")!.lowerBound))
        let slip = try PayslipReader.read(texts: [text])
        XCTAssertNil(slip.taxablePayToDate)
        XCTAssertNil(slip.taxToDate)
        XCTAssertFalse(slip.isChecked)
    }

    func testOtherFilesAreRefused() {
        XCTAssertThrowsError(try PayslipReader.read(texts: ["Gross £5.00"])) { XCTAssertEqual($0 as? PayslipError, .notRecognised) }
        XCTAssertThrowsError(try PayslipReader.read(texts: [Self.stacked.replacingOccurrences(of: "06/06/2025", with: "June")])) {
            XCTAssertEqual($0 as? PayslipError, .missingDate)
        }
        XCTAssertEqual(TaxDocument.recognise(Self.rows), .payslip)
    }

    func testTheLatestPayslipSetsTheYearsPayAndAnOlderOneChangesNothing() {
        var book = PropertyBook()
        func record(_ day: Int, _ pay: Decimal, _ employer: String = "Umbrella") -> Bool {
            book.record(payslipDated: TaxYear.day(2025, 6, day), taxablePay: pay, taxDeducted: 10, person: .me, employer: employer)
        }
        XCTAssertTrue(record(6, 100))
        XCTAssertTrue(record(20, 300, " umbrella "))
        XCTAssertFalse(record(13, 200))
        XCTAssertEqual(book.pay.map(\.taxablePay), [300])
        XCTAssertEqual(book.pay[0].taxYear, "2025-26")
        XCTAssertFalse(book.pay[0].isShared)
        XCTAssertFalse(book.record(payslipDated: TaxYear.day(2020, 6, 1), taxablePay: 1, taxDeducted: 0, person: .me, employer: "Umbrella"))
    }

    func testAnEntryTypedInIsUpdatedAndKeepsItsOtherDetails() {
        var typed = TaxPay(id: "job", person: .me, taxYear: "2025-26", employer: "Umbrella", taxablePay: 1, taxDeducted: 0,
                           reliefAtSourcePension: 50, isShared: true)
        var book = PropertyBook(pay: [typed])
        // Typed figures, perhaps a P60's, are only replaced when you say so.
        XCTAssertFalse(book.record(payslipDated: TaxYear.day(2025, 6, 6), taxablePay: 100, taxDeducted: 10, person: .me, employer: "Umbrella"))
        XCTAssertEqual(book.pay, [typed])
        XCTAssertTrue(book.record(payslipDated: TaxYear.day(2025, 6, 6), taxablePay: 100, taxDeducted: 10, person: .me, employer: "Umbrella",
                                  replacingTyped: true))
        XCTAssertEqual(book.pay.map(\.id), ["job"])
        XCTAssertEqual(book.pay[0].reliefAtSourcePension, 50)
        XCTAssertTrue(book.pay[0].isShared)
        typed.enteredBy = .partner
        book = PropertyBook(pay: [typed])
        XCTAssertFalse(book.record(payslipDated: TaxYear.day(2025, 6, 6), taxablePay: 100, taxDeducted: 10, person: .me, employer: "Umbrella",
                                   replacingTyped: true))
        XCTAssertEqual(book.pay, [typed])
    }

    func testAPartnersSharedEntryForTheSameEmployerIsNeverTouched() throws {
        var theirs = PropertyBook()
        theirs.record(payslipDated: TaxYear.day(2025, 6, 6), taxablePay: 300, taxDeducted: 30, person: .me, employer: "Umbrella")
        // As it arrives on the other person's device: the same name, but their partner's.
        var arrived = theirs.pay[0]
        arrived.person = .partner
        arrived.enteredBy = .partner
        arrived.isShared = true
        var book = PropertyBook(pay: [arrived])
        XCTAssertTrue(book.record(payslipDated: TaxYear.day(2025, 6, 6), taxablePay: 100, taxDeducted: 10, person: .me, employer: "Umbrella"))
        XCTAssertEqual(book.pay.count, 2)
        XCTAssertEqual(book.pay[0], arrived)
        XCTAssertNotEqual(book.pay[1].id, arrived.id)
        // Even the very same figures don't take its place.
        book = PropertyBook(pay: [arrived])
        XCTAssertTrue(book.record(payslipDated: TaxYear.day(2025, 6, 6), taxablePay: 300, taxDeducted: 30, person: .me, employer: "Umbrella"))
        XCTAssertEqual(Set(book.pay.map(\.id)).count, 2)
    }

    func testOnePayslipImportedOnTwoDevicesMakesOneEntryAndTwoEntriesAreNoticed() {
        func imported(_ pay: Decimal, _ day: Int) -> TaxPay {
            var book = PropertyBook()
            book.record(payslipDated: TaxYear.day(2025, 6, day), taxablePay: pay, taxDeducted: 10, person: .me, employer: "Umbrella")
            return book.pay[0]
        }
        XCTAssertEqual(imported(100, 6).id, imported(100, 6).id)
        let book = PropertyBook(pay: [imported(100, 6), imported(200, 13)])
        XCTAssertEqual(book.repeatedPay(in: TaxYear(startYear: 2025)), ["Umbrella"])
        XCTAssertEqual(book.repeatedPay(in: TaxYear(startYear: 2026)), [])
    }

    func testAnEarlierJobsFiguresAreNeverTakenAsThisOnes() throws {
        let text = Self.stacked + "\nPrevious Employment Taxable Pay £25,000.00\nPrevious Employment Income Tax £5,000.00"
        let slip = try PayslipReader.read(texts: [text])
        XCTAssertEqual(slip.taxablePayToDate, 19_800)
        XCTAssertEqual(slip.taxToDate, 2_700)
        // Two different figures that could be pay to date: neither is chosen.
        let unclear = try PayslipReader.read(texts: [Self.stacked + "\nTaxable Pay £25,000.00"])
        XCTAssertNil(unclear.taxablePayToDate)
        XCTAssertFalse(unclear.isChecked)
    }

    func testAFileOfSeveralPayslipsIsRefused() {
        let two = Self.stacked + "\n" + Self.stacked.replacingOccurrences(of: "06/06/2025", with: "13/06/2025")
        XCTAssertThrowsError(try PayslipReader.read(texts: [Self.stacked, two])) {
            XCTAssertEqual($0 as? PayslipError, .severalPayslips)
        }
    }
}
