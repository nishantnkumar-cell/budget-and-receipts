import XCTest
@testable import BudgetCore

final class MonthlyBudgetReportTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ day: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func tx(_ month: Int, _ d: Int, _ amount: String, _ category: String, splits: [TransactionSplit] = []) -> BankTransaction {
        BankTransaction(date: day(month, d), merchant: "M", amount: money(amount), category: category, fingerprint: UUID().uuidString, splits: splits)
    }

    private var calculator: BudgetCalculator { BudgetCalculator(calendar: calendar) }

    func testOnlyTheSelectedMonthCounts() {
        let transactions = [tx(10, 3, "-40.00", "Groceries"), tx(9, 30, "-99.00", "Groceries"), tx(11, 1, "-5.00", "Groceries")]
        XCTAssertEqual(calculator.spendingByCategory(transactions, month: day(10, 15)), ["Groceries": money("40.00")])
    }

    func testMonthBoundaryUsesLocalTime() {
        // 23:30 on 31 October in London is still October.
        let late = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 30))!
        let transaction = BankTransaction(date: late, merchant: "M", amount: money("-1.00"), category: "Groceries", fingerprint: "late")
        XCTAssertEqual(calculator.spendingByCategory([transaction], month: day(10, 1))["Groceries"], money("1.00"))
        XCTAssertNil(calculator.spendingByCategory([transaction], month: day(11, 1))["Groceries"])
    }

    func testSplitsCountInTheirOwnCategories() {
        let splits = [
            TransactionSplit(label: "Food", category: "Groceries", amount: money("30.00")),
            TransactionSplit(label: "Socks", category: "Shopping", amount: money("10.00"))
        ]
        let spent = calculator.spendingByCategory([tx(10, 3, "-40.00", "Uncategorised", splits: splits)], month: day(10, 1))
        XCTAssertEqual(spent, ["Groceries": money("30.00"), "Shopping": money("10.00")])
    }

    func testRefundReducesItsCategory() {
        let spent = calculator.spendingByCategory([tx(10, 3, "-50.00", "Shopping"), tx(10, 9, "12.99", "Shopping")], month: day(10, 1))
        XCTAssertEqual(spent["Shopping"], money("37.01"))
    }

    func testTransfersAndIncomeAreNotSpending() {
        let transactions = [
            tx(10, 1, "2500.00", "Income"),
            tx(10, 2, "-300.00", "Card payment"),
            tx(10, 2, "-100.00", "Internal transfer"),
            tx(10, 4, "100.00", "Internal transfer"),
            tx(10, 5, "-20.00", "Eating out")
        ]
        let report = calculator.report(transactions, budgets: [], month: day(10, 1))
        XCTAssertEqual(report.income, money("2500.00"))
        XCTAssertEqual(report.spending, money("20.00"))
        XCTAssertEqual(report.net, money("2480.00"))
    }

    func testUncategorisedCreditIsIncomeNotRefund() {
        let report = calculator.report([tx(10, 1, "50.00", "Uncategorised")], budgets: [], month: day(10, 1))
        XCTAssertEqual(report.income, money("50.00"))
        XCTAssertEqual(report.spending, 0)
    }

    func testBudgetCarriesForwardUntilChanged() {
        let budgets = [
            MonthlyBudget(category: "Groceries", limit: money("300"), month: day(8, 10)),
            MonthlyBudget(category: "Groceries", limit: money("350"), month: day(10, 20))
        ]
        XCTAssertNil(calculator.budget(for: "Groceries", in: budgets, month: day(7, 1)))
        XCTAssertEqual(calculator.budget(for: "Groceries", in: budgets, month: day(9, 1))?.limit, money("300"))
        XCTAssertEqual(calculator.budget(for: "Groceries", in: budgets, month: day(10, 1))?.limit, money("350"), "A budget set later in the month applies to the whole month")
        XCTAssertEqual(calculator.budget(for: "Groceries", in: budgets, month: day(12, 1))?.limit, money("350"))
    }

    func testReportLines() {
        let budgets = [MonthlyBudget(category: "Groceries", limit: money("100"), month: day(10, 1))]
        let report = calculator.report([tx(10, 3, "-120.00", "Groceries"), tx(10, 4, "-15.00", "Transport")], budgets: budgets, month: day(10, 1))
        let groceries = report.lines.first { $0.category == "Groceries" }!
        XCTAssertEqual(groceries.remaining, money("-20.00"))
        XCTAssertTrue(groceries.isOverBudget)
        XCTAssertEqual(groceries.progress!, 1.2, accuracy: 0.0001)
        let transport = report.lines.first { $0.category == "Transport" }!
        XCTAssertNil(transport.limit)
        XCTAssertFalse(transport.isOverBudget)
        XCTAssertEqual(report.lines.map(\.category), ["Groceries", "Transport"], "Lines follow the category order")
    }
}
