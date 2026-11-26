import BudgetCore
import XCTest
@testable import TaxCore

final class IndiaStatementTests: XCTestCase {
    private func day(_ date: Date) -> String { PropertyLedger.day(date) }

    func testReadsATabSeparatedSBIDownload() throws {
        let statement = try IndiaStatement.read(Data(IndiaSample.sbiStatement.utf8))
        XCTAssertEqual(statement.lines.map(\.amount), [25_000, -4_500, 1_200, -360])
        XCTAssertEqual(statement.lines.map(\.balance), [125_000, 120_500, 121_700, 121_340])
        XCTAssertEqual(day(statement.lines[0].date), "1 Apr 2026")
        XCTAssertEqual(statement.lines[2].narration, "CREDIT INTEREST--")
        XCTAssertEqual(statement.lastFour, "4321")
        XCTAssertNil(statement.balanceDifference)
    }

    func testReadsAnICICIDownloadSavedAsCSV() throws {
        let statement = try IndiaStatement.read(text: IndiaSample.iciciStatement)
        XCTAssertEqual(statement.lines.map(\.amount), [200_000, -10_000, 3_650])
        XCTAssertEqual(day(statement.lines[2].date), "30 Jun 2026")
        XCTAssertEqual(statement.lastFour, "8765")
        XCTAssertNil(statement.balanceDifference)
    }

    func testReadsOtherWordingsAndDates() throws {
        let text = """
        Date,Details,Ref No/Cheque No,Debit(₹),Credit(₹),Balance(₹)
        01-04-2026,"A, B",x,-,1000.00,1000.00Cr
        02-Apr-26,C,x,INR 250.50,,749.50
        """
        let statement = try IndiaStatement.read(Data("\u{FEFF}\(text)".replacingOccurrences(of: "\n", with: "\r\n").utf8))
        XCTAssertEqual(statement.lines.map(\.amount), [1_000, Decimal(string: "-250.50")!])
        XCTAssertEqual(statement.lines.map(\.narration), ["A, B", "C"])
        XCTAssertEqual(statement.lines.map { day($0.date) }, ["1 Apr 2026", "2 Apr 2026"])
    }

    func testAMissingLineShowsInTheBalance() throws {
        var rows = IndiaSample.sbiStatement.components(separatedBy: "\n")
        rows.remove(at: 5)
        let statement = try IndiaStatement.read(text: rows.joined(separator: "\n"))
        XCTAssertEqual(statement.balanceDifference, -4_500)
    }

    func testTotalsAreSkippedButAPaymentIsNeverDroppedQuietly() throws {
        let header = "Date,Narration,Withdrawal,Deposit,Balance\n01/04/2026,A,10,,90\n"
        XCTAssertEqual(try IndiaStatement.read(text: header + ",Total,10,0,\n,Closing Balance,,,90\n").lines.count, 1)
        XCTAssertThrowsError(try IndiaStatement.read(text: header + "someday,B,5,,85")) {
            XCTAssertEqual($0 as? IndiaStatementError, .badDate(line: 3, value: "someday"))
        }
        XCTAssertThrowsError(try IndiaStatement.read(text: header + "02/04/2026,B,five,,85")) {
            XCTAssertEqual($0 as? IndiaStatementError, .badAmount(line: 3, value: "five"))
        }
        XCTAssertThrowsError(try IndiaStatement.read(text: header + "02/04/2026,B,5,5,85"))
    }

    func testExcelPDFAndOtherFilesAreExplained() {
        for bytes in [[0xD0, 0xCF, 0x11, 0xE0], [0x50, 0x4B, 0x03, 0x04], Array("%PDF-1.7".utf8), Array("<html><table>".utf8)] as [[UInt8]] {
            XCTAssertThrowsError(try IndiaStatement.read(Data(bytes))) {
                guard case .notText = $0 as? IndiaStatementError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try IndiaStatement.read(text: "Date,Description,Amount\n01/04/2026,A,5")) {
            XCTAssertEqual($0 as? IndiaStatementError, .noHeader)
        }
        XCTAssertThrowsError(try IndiaStatement.read(text: "Date,Narration,Debit,Credit\n")) {
            XCTAssertEqual($0 as? IndiaStatementError, .empty)
        }
    }

    func testImportingAgainOrAnOverlapAddsNothingTwice() throws {
        let statement = try IndiaStatement.read(text: IndiaSample.sbiStatement)
        let first = statement.entries(for: "a", existing: [])
        XCTAssertEqual(first.new.count, 4)
        let again = statement.entries(for: "a", existing: first.new)
        XCTAssertEqual(again.new, [])
        XCTAssertEqual(again.alreadyThere, 4)
        // The same line worded differently in a later download is known by its balance.
        let reworded = try IndiaStatement.read(text: IndiaSample.sbiStatement.replacingOccurrences(of: "NEFT SAMPLE RENT", with: "NEFT*SAMPLE*RENT*"))
        XCTAssertEqual(reworded.entries(for: "a", existing: first.new).new, [])
        // Another account's lines are its own.
        XCTAssertEqual(statement.entries(for: "b", existing: first.new).new.count, 4)
    }

    func testAPaymentsWordingNeverEndsTheStatement() throws {
        let text = "Date,Narration,Debit,Credit\n01/04/2026,LEGENDS CAFE,10,\n02/04/2026,CHEQUE STATUS FEE,5,\n03/04/2026,TEA,1,\n,Cheque Status,,\n12,000123,x,y\n"
        XCTAssertEqual(try IndiaStatement.read(text: text).lines.map(\.amount), [-10, -5, -1])
    }

    func testAWrappedDescriptionNeverEndsTheStatement() throws {
        let text = "Date,Narration,Debit,Credit\n01/04/2026,UPI,10,\n,LEGENDS CAFE,,\n02/04/2026,SALARY,,5\nLegends,,,\n12,000123,x,y\n"
        XCTAssertEqual(try IndiaStatement.read(text: text).lines.map(\.amount), [-10, 5])
    }

    func testADateThatCantBeReadIsReportedWhateverTheWording() {
        let text = "Date,Narration,Debit,Credit\n01/04/2026,A,1,\n02/04/2026 10:22,MIN BALANCE CHARGES,100,\n"
        XCTAssertThrowsError(try IndiaStatement.read(text: text)) {
            XCTAssertEqual($0 as? IndiaStatementError, .badDate(line: 3, value: "02/04/2026 10:22"))
        }
    }

    func testFilesWithAndWithoutABalanceColumnDontDouble() throws {
        let with = try IndiaStatement.read(text: "Date,Narration,Debit,Credit,Balance\n30/06/2026,CREDIT INTEREST,,100,200\n")
        let without = try IndiaStatement.read(text: "Date,Narration,Debit,Credit\n30/06/2026,Credit Interest,,100\n")
        for (first, second) in [(with, without), (without, with)] {
            let stored = first.entries(for: "a", existing: []).new
            XCTAssertEqual(second.entries(for: "a", existing: stored).new, [])
            XCTAssertEqual(second.entries(for: "a", existing: stored).alreadyThere, 1)
        }
    }

    func testAnOverlapAddsOnlyTheExtraIdenticalPayment() throws {
        let one = try IndiaStatement.read(text: "Date,Narration,Debit,Credit\n01/04/2026,TEA,10,\n")
        let two = try IndiaStatement.read(text: "Date,Narration,Debit,Credit\n01/04/2026,TEA,10,\n01/04/2026,TEA,10,\n")
        let stored = one.entries(for: "a", existing: []).new
        let more = two.entries(for: "a", existing: stored)
        XCTAssertEqual(more.alreadyThere, 1)
        XCTAssertEqual(more.new.count, 1)
        XCTAssertEqual(two.entries(for: "a", existing: stored + more.new).new, [])
    }

    func testTwoIdenticalPaymentsInOneFileAreBothKept() throws {
        let text = "Date,Narration,Debit,Credit\n01/04/2026,TEA,10,\n01/04/2026,TEA,10,\n"
        let entries = try IndiaStatement.read(text: text).entries(for: "a", existing: []).new
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
    }
}
