import XCTest
@testable import BudgetCore

final class PDFStatementTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func parse(_ lines: [String]) throws -> [StatementRow] {
        try PDFStatementParser.parse(lines, fallbackYear: 2026, timeZone: calendar.timeZone)
    }

    private func ymd(_ date: Date) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(p.year!)-\(p.month!)-\(p.day!)"
    }

    /// Text as PDFKit extracts it from a typical UK current account statement.
    private let current = [
        "Your Current Account statement",
        "Mrs A Kumar",
        "Account number 12345678   Sort code 12-34-56",
        "1 October 2026 to 31 October 2026",
        "Date Description Paid out Paid in Balance",
        "01 Oct BALANCE BROUGHT FORWARD 1,200.00",
        "03 Oct CARD PAYMENT TO TESCO STORES 3297 12.40 1,187.60",
        "05 Oct ACME LTD SALARY 2,500.00 3,687.60",
        "05 Oct DIRECT DEBIT BRITISH GAS 85.00 3,602.60",
        "12 Oct REFUND AMAZON 9.99 3,612.59",
        "31 Oct BALANCE CARRIED FORWARD 3,612.59",
    ]

    func testCurrentAccountUsesTheBalanceForSigns() throws {
        let rows = try parse(current)
        XCTAssertEqual(rows.map(\.description), ["CARD PAYMENT TO TESCO STORES 3297", "ACME LTD SALARY", "DIRECT DEBIT BRITISH GAS", "REFUND AMAZON"])
        XCTAssertEqual(rows.map(\.amount), [money("-12.40"), money("2500.00"), money("-85.00"), money("9.99")])
        XCTAssertEqual(rows.map { ymd($0.date) }, ["2026-10-3", "2026-10-5", "2026-10-5", "2026-10-12"])
        XCTAssertEqual(rows.first?.accountNumber, "12345678")
    }

    func testSummaryCheck() throws {
        let lines = ["Statement", "Payments In £2,509.99", "Payments Out £97.40"] + current
        XCTAssertNil(PDFStatementParser.summaryDifference(lines, rows: try parse(lines)))
        let wrong = ["Statement", "Payments In £2,509.99", "Payments Out £100.00"] + current
        XCTAssertEqual(PDFStatementParser.summaryDifference(wrong, rows: try parse(wrong)), money("2.60"))
    }

    func testCardRowsWithTwoDatesUseTheTransactionDate() throws {
        let rows = try parse([
            "Credit Card Statement", "Previous Balance 100.00", "Debits 30.00", "Credits 20.00",
            "Received By Us Transaction Date Details Amount",
            "22 Jul 26 21 Jul 26 ))) SAINSBURYS S/MKTS HAMPTON 25.00",
            "25 Jul 26 24 Jul 26 ))) SAINSBURYS S/MKTS ST CLARES 20.00CR",
            "26 Jul 26 26 Jul 26 IAP Vinted London 5.00",
            "Summary Of Interest On This Statement",
            "NO INTEREST CHARGED ON THIS STATEMENT",
            "Your Credit Card Statement",
            "Estimated interest - next month 33.86",
        ])
        XCTAssertEqual(rows.map(\.description), ["SAINSBURYS S/MKTS HAMPTON", "SAINSBURYS S/MKTS ST CLARES", "IAP Vinted London"])
        XCTAssertEqual(rows.map(\.amount), [money("-25.00"), money("20.00"), money("-5.00")])
        XCTAssertEqual(ymd(rows[0].date), "2026-7-21")
    }

    func testRecognisedAsAStatementNotAReceipt() {
        XCTAssertTrue(PDFStatementParser.looksLikeStatement(current))
        XCTAssertFalse(PDFStatementParser.looksLikeStatement(["TESCO", "MILK 1.20", "BREAD 1.10", "TOTAL 2.30", "12/10/2026 14:32", "VISA ****1234"]))
    }

    func testCreditCardWithoutBalanceColumn() throws {
        let rows = try parse([
            "Credit card statement",
            "Card number **** **** **** 4321",
            "Statement period 15 Dec 2025 to 14 Jan 2026",
            "16 Dec AMAZON.CO.UK 15.99",
            "28 Dec PAYMENT RECEIVED - THANK YOU 200.00CR",
            "03 Jan TFL TRAVEL 7.80",
            "05 Jan NETFLIX.COM 10.99",
        ])
        XCTAssertEqual(rows.map(\.amount), [money("-15.99"), money("200.00"), money("-7.80"), money("-10.99")])
        XCTAssertEqual(rows.map { ymd($0.date) }, ["2025-12-16", "2025-12-28", "2026-1-3", "2026-1-5"], "Years follow the statement period across New Year")
        XCTAssertEqual(rows.first?.accountNumber, "4321")
    }

    func testFullDatesAndSlashes() throws {
        let rows = try parse([
            "Statement",
            "Date Description Paid out Balance",
            "03/10/2026 COSTA COFFEE 3.20 996.80",
            "04/10/26 PRET 4.50 992.30",
        ])
        XCTAssertEqual(rows.map { ymd($0.date) }, ["2026-10-3", "2026-10-4"])
        XCTAssertEqual(rows.map(\.amount), [money("-3.20"), money("-4.50")])
    }

    func testLineWithoutDateUsesThePreviousDate() throws {
        let rows = try parse([
            "Statement", "Balance",
            "01 Oct BALANCE BROUGHT FORWARD 100.00",
            "03 Oct TESCO 10.00 90.00",
            "COSTA 3.00 87.00",
        ])
        XCTAssertEqual(rows.map { ymd($0.date) }, ["2026-10-3", "2026-10-3"])
        XCTAssertEqual(rows.last?.amount, money("-3.00"))
    }

    func testNothingFoundIsAnError() {
        XCTAssertThrowsError(try parse(["Statement", "No transactions this month"]))
    }

    // Layouts below are made up, shaped like real UK statements (no real data).

    func testAmexStyleMonthFirstDatesForeignSpendAndCreditOnTheNextLine() throws {
        let lines = [
            "Statement of Account", "Credit Limit £ 5,000.00",
            "Previous Closing Balance New Credits New Debits Closing Balance",
            "£100.00 - £100.00 + = £37.50 £ 37.50",
            "Statement Period From 6 August to 5 September 2026",
            "Date Date Transaction Details Foreign Spend Amount £",
            "Aug 17 Aug 17 PAYMENT RECEIVED - THANK YOU 100.00", "CR",
            "Aug 5 Aug 5 CORNER SHOP LONDON 7.50", "GOODS",
            "Aug 19 Aug 19 TAXI AMSTERDAM 35.00 30.00",
        ]
        let rows = try parse(lines)
        XCTAssertEqual(rows.map(\.amount), [money("100.00"), money("-7.50"), money("-30.00")])
        XCTAssertNil(PDFStatementParser.summaryDifference(lines, rows: rows))
    }

    func testPaymentsWhoseSignsOnlyTheBalanceCanTell() throws {
        // Two lines share one balance, a "BP" code is money in here, and a time looks like money.
        let lines = [
            "Your Account statement", "Payments In 500.00", "Payments Out 160.00",
            "Date Payment type and details £ Paid out £ Paid in £ Balance",
            "15 Aug 26 Balance brought forward . 1,000.00",
            "20 Aug 26 BP SMITH J", "RENT SHARE 500.00",
            "ATM CASH AUG20", "HIGH ST@19.06 150.00 1,350.00",
            "02 Sep 26 DD PHONE CO 10.00",
            "Balance carried forward 1,340.00",
            "small print", "more small print", "and more",
            "Balance brought forward 1,340.00",
        ]
        let rows = try parse(lines)
        XCTAssertEqual(rows.map(\.amount), [money("500.00"), money("-150.00"), money("-10.00")])
        XCTAssertNil(PDFStatementParser.summaryDifference(lines, rows: rows))
    }

    func testNewPageWithoutADateAndCardTotals() throws {
        let lines = [
            "Statement", "Paid In £0.00", "Withdrawn £9.00",
            "Date Description Paid In(£) Withdrawn(£) Balance(£)",
            "23 JUL 2026 BROUGHT FORWARD 100.00",
            "24 JUL Card Transaction CD BAKERY", "LONDON GB 4.00 96.00",
            "Registered in England and Wales", "Authorised by the regulator", "RETSTMT",
            "BROUGHT FORWARD 96.00",
            "Card Transaction CD CAFE", "LONDON GB 5.00 91.00",
        ]
        let rows = try parse(lines)
        XCTAssertEqual(rows.map { ymd($0.date) }, ["2026-7-24", "2026-7-24"])
        XCTAssertNil(PDFStatementParser.summaryDifference(lines, rows: rows))
    }
}
