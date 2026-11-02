import XCTest
@testable import BudgetCore

final class StatementImportTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        return calendar
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/statements/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every fixture holds the same five lines; see Fixtures/statements/README.md.
    private func assertStandardRows(_ rows: [StatementRow], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rows.map(\.amount), [money("2500.00"), money("-45.67"), money("-3.20"), money("-3.20"), money("12.99")], file: file, line: line)
        XCTAssertEqual(rows.map(\.description), ["SALARY ACME LTD", "TESCO STORES 2041", "COSTA COFFEE", "COSTA COFFEE", "AMAZON REFUND, \"BOOKS\""], file: file, line: line)
        XCTAssertEqual(rows.map { calendar.component(.day, from: $0.date) }, [1, 3, 3, 3, 15], file: file, line: line)
        XCTAssertTrue(rows.allSatisfy { calendar.component(.month, from: $0.date) == 10 }, file: file, line: line)
    }

    func testSimpleCSVWithGuessedColumns() throws {
        let text = try fixture("simple-uk.csv")
        let header = CSVReader.records(text)[0]
        let mapping = try XCTUnwrap(CSVColumnMapping.guess(header: header))
        assertStandardRows(try StatementImporter.parseCSV(text, mapping: mapping, timeZone: london))
    }

    func testPaidInPaidOutCSVWithNamedMonths() throws {
        let text = try fixture("paid-in-out.csv")
        let mapping = try XCTUnwrap(CSVColumnMapping.guess(header: CSVReader.records(text)[0]))
        XCTAssertEqual(mapping.description, 2)
        XCTAssertNil(mapping.amount)
        assertStandardRows(try StatementImporter.parseCSV(text, mapping: mapping, timeZone: london))
    }

    func testOFX() throws {
        let rows = try StatementImporter.parseOFX(try fixture("statement.ofx"), timeZone: london)
        assertStandardRows(rows)
        XCTAssertEqual(rows.compactMap(\.bankID), ["T1", "T2", "T3", "T4", "T5"])
    }

    func testQIF() throws {
        assertStandardRows(try StatementImporter.parseQIF(try fixture("statement.qif"), timeZone: london))
    }

    func testImportingTheSameFileTwiceAddsNothing() throws {
        let rows = try StatementImporter.parseQIF(try fixture("statement.qif"), timeZone: london)
        let first = StatementImporter.prepare(rows, existing: [], calendar: calendar)
        XCTAssertEqual(first.newTransactions.count, 5, "Both identical coffees are real and must import")
        XCTAssertEqual(Set(first.newTransactions.map(\.fingerprint)).count, 5)

        let second = StatementImporter.prepare(rows, existing: first.newTransactions, calendar: calendar)
        XCTAssertTrue(second.newTransactions.isEmpty)
        XCTAssertEqual(second.duplicates.count, 5)
    }

    func testOverlappingStatementOnlyAddsNewLines() throws {
        let rows = try StatementImporter.parseQIF(try fixture("statement.qif"), timeZone: london)
        let first = StatementImporter.prepare(Array(rows.prefix(3)), existing: [], calendar: calendar)
        let second = StatementImporter.prepare(rows, existing: first.newTransactions, calendar: calendar)
        XCTAssertEqual(second.newTransactions.map(\.amount), [money("-3.20"), money("12.99")])
    }

    func testManualEntryWithSameDayAndAmountIsFlagged() throws {
        let rows = try StatementImporter.parseQIF(try fixture("statement.qif"), timeZone: london)
        let manual = BankTransaction(date: rows[1].date, merchant: "Tesco", amount: money("-45.67"), fingerprint: "manual-1")
        let result = StatementImporter.prepare(rows, existing: [manual], calendar: calendar)
        XCTAssertEqual(result.newTransactions.count, 5)
        XCTAssertEqual(result.possibleDuplicates.map(\.amount), [money("-45.67")])
    }

    func testFingerprintIsReadableAndStable() {
        let date = DateParser.makeDate(year: 2026, month: 10, day: 3, timeZone: london)!
        let row = StatementRow(date: date, description: "Costa Coffee", amount: money("-3.20"))
        XCTAssertEqual(StatementImporter.baseFingerprint(row, calendar: calendar), "stmt:2026-10-03|-3.2|COSTA COFFEE")
    }

    func testAmountFormats() {
        XCTAssertEqual(AmountParser.parse("£1,234.56", decimalComma: false), money("1234.56"))
        XCTAssertEqual(AmountParser.parse("(12.50)", decimalComma: false), money("-12.50"))
        XCTAssertEqual(AmountParser.parse("12.50 DR", decimalComma: false), money("-12.50"))
        XCTAssertEqual(AmountParser.parse("12.50CR", decimalComma: false), money("12.50"))
        XCTAssertEqual(AmountParser.parse("1.234,56", decimalComma: true), money("1234.56"))
        XCTAssertEqual(AmountParser.parse("-0.10", decimalComma: false), money("-0.10"))
        XCTAssertNil(AmountParser.parse("abc", decimalComma: false))
        XCTAssertNil(AmountParser.parse("", decimalComma: false))
    }

    func testDateOrders() {
        let uk = DateParser(order: .dayMonthYear, timeZone: london)
        let us = DateParser(order: .monthDayYear, timeZone: london)
        XCTAssertEqual(calendar.component(.month, from: uk.parse("03/10/2026")!), 10)
        XCTAssertEqual(calendar.component(.month, from: us.parse("03/10/2026")!), 3)
        XCTAssertEqual(calendar.component(.day, from: uk.parse("2026-02-28")!), 28)
        XCTAssertNil(uk.parse("31/02/2026"), "31 February must be rejected, not rolled into March")
        XCTAssertEqual(calendar.component(.year, from: uk.parse("03/10/26")!), 2026)
    }

    func testBadLinesReportTheirLineNumber() {
        let text = "Date,Description,Amount\n01/10/2026,OK,1.00\nnot a date,BAD,2.00\n"
        let mapping = CSVColumnMapping(date: 0, description: 1, amount: 2)
        XCTAssertThrowsError(try StatementImporter.parseCSV(text, mapping: mapping)) { error in
            XCTAssertEqual(error as? StatementImportError, .badDate(line: 3, value: "not a date"))
        }
    }

    func testFormatFromFileName() {
        XCTAssertEqual(StatementFormat(fileName: "Oct.OFX"), .ofx)
        XCTAssertEqual(StatementFormat(fileName: "oct.qfx"), .ofx)
        XCTAssertEqual(StatementFormat(fileName: "oct.qif"), .qif)
        XCTAssertEqual(StatementFormat(fileName: "oct.csv"), .csv)
    }
}
