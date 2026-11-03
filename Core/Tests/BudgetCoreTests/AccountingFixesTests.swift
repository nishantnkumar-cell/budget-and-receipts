import XCTest
@testable import BudgetCore

/// Refunds, card statement signs and running balances, from the accounting review.
final class AccountingFixesTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = london
        return calendar
    }

    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }

    private func credit(_ merchant: String, _ amount: String) -> BankTransaction {
        BankTransaction(date: day(10), merchant: merchant, amount: money(amount), fingerprint: merchant)
    }

    // MARK: Refunds

    func testRefundGoesBackToTheShopsCategory() {
        let categoriser = Categoriser(history: [], rules: RulesEngine.starterRules)
        XCTAssertEqual(categoriser.suggest(for: credit("AMAZON REFUND", "80.00"))?.category, "Shopping")
        XCTAssertEqual(categoriser.suggest(for: credit("TESCO STORES 3297", "4.50"))?.category, "Groceries", "Money back from a supermarket")
        let unknown = categoriser.suggest(for: credit("REFUND XYZ TRADING", "20.00"))
        XCTAssertEqual(unknown.map { FinanceCategories.label($0.category, $0.subcategory) }, "Income › Refund", "A shop the app doesn't know")
        XCTAssertEqual(categoriser.suggest(for: credit("ACME LTD SALARY", "2500.00"))?.category, "Income")
    }

    func testLearnedShopCategoryAppliesToItsRefunds() {
        let bought = BankTransaction(date: day(1), merchant: "SADDA SUPERSTORE", amount: money("-30"), category: "Groceries", fingerprint: "a")
        let categoriser = Categoriser(history: [bought], rules: RulesEngine.starterRules)
        XCTAssertEqual(categoriser.suggest(for: credit("SADDA SUPERSTORE REFUND", "5.00"))?.category, "Groceries")
    }

    func testRefundsArentIncome() {
        let calculator = BudgetCalculator(calendar: calendar)
        let shoes = BankTransaction(date: day(2), merchant: "NEXT", amount: money("-80"), category: "Shopping", fingerprint: "1")
        let back = BankTransaction(date: day(9), merchant: "NEXT REFUND", amount: money("80"), category: "Shopping", fingerprint: "2")
        var unknown = BankTransaction(date: day(9), merchant: "REFUND XYZ", amount: money("20"), category: "Income", fingerprint: "3")
        unknown.subcategory = "Refund"
        let pay = BankTransaction(date: day(1), merchant: "ACME SALARY", amount: money("2500"), category: "Income", fingerprint: "4")
        XCTAssertEqual(calculator.income([shoes, back, unknown, pay], month: day(1)), 2500)
        XCTAssertEqual(calculator.spendingByCategory([shoes, back], month: day(1))["Shopping"], 0)
    }

    // MARK: Card statement signs

    func testAmexStyleCSVIsTurnedRound() {
        let rows = [StatementRow(date: day(1), description: "TESCO STORES", amount: money("45.67")),
                    StatementRow(date: day(2), description: "NETFLIX.COM", amount: money("10.99")),
                    StatementRow(date: day(3), description: "AMAZON MARKETPLACE REFUND", amount: money("-12.99")),
                    StatementRow(date: day(5), description: "PAYMENT RECEIVED - THANK YOU", amount: money("-500.00"))]
        let fixed = StatementImporter.fixingCardSigns(rows)
        XCTAssertTrue(fixed.flipped)
        XCTAssertEqual(fixed.rows.map(\.amount), [money("-45.67"), money("-10.99"), money("12.99"), money("500.00")])
    }

    func testBankStatementSignsAreLeftAlone() {
        let rows = [StatementRow(date: day(1), description: "TESCO STORES", amount: money("-45.67")),
                    StatementRow(date: day(5), description: "PAYMENT RECEIVED - THANK YOU", amount: money("500.00"))]
        XCTAssertFalse(StatementImporter.fixingCardSigns(rows).flipped)
        let noPayment = [StatementRow(date: day(1), description: "REFUND", amount: money("45.67"))]
        XCTAssertFalse(StatementImporter.fixingCardSigns(noPayment).flipped, "Without a bill payment line there's no telling")
    }

    // MARK: Running balance

    func testRunningBalanceIsCheckedInEitherOrder() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/statements/paid-in-out.csv")
        let text = try String(contentsOf: url, encoding: .utf8)
        let mapping = try XCTUnwrap(CSVColumnMapping.guess(header: CSVReader.firstRecord(text)))
        XCTAssertEqual(mapping.balance, 5)
        let rows = try StatementImporter.parseCSV(text, mapping: mapping, timeZone: london)
        XCTAssertEqual(rows.last?.balance, money("2560.92"))
        XCTAssertNil(StatementImporter.balanceDifference(rows), "Every line is there")
        XCTAssertNil(StatementImporter.balanceDifference(rows.reversed()), "Newest first works too")
        var missing = rows
        missing.remove(at: 2)
        XCTAssertEqual(StatementImporter.balanceDifference(missing), money("-3.20"), "A coffee is missing")
        let noBalance = rows.map { StatementRow(date: $0.date, description: $0.description, amount: $0.amount) }
        XCTAssertNil(StatementImporter.balanceDifference(noBalance))
    }
}
