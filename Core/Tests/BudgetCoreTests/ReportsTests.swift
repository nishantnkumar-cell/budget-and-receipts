import XCTest
@testable import BudgetCore

final class ReportsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private var calculator: BudgetCalculator { BudgetCalculator(calendar: calendar) }

    private func day(_ month: Int, _ d: Int, year: Int = 2026) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: d, hour: 12))! }

    private func tx(_ date: Date, _ merchant: String, _ amount: String, _ category: String, sub: String? = nil) -> BankTransaction {
        var transaction = BankTransaction(date: date, merchant: merchant, amount: money(amount), category: category, fingerprint: UUID().uuidString)
        transaction.subcategory = sub
        return transaction
    }

    func testCashFlowSkipsMonthsBeforeTheFirstPayment() {
        let transactions = [
            tx(day(9, 1), "ACME LTD", "2000", "Income"),
            tx(day(9, 5), "TESCO STORES 123", "-150", "Groceries"),
            tx(day(10, 1), "ACME LTD", "2000", "Income"),
            tx(day(10, 8), "TESCO STORES 123", "-250", "Groceries"),
            tx(day(10, 9), "AMEX", "-900", "Card payment"),
        ]
        let report = CashFlowReport.make(transactions, endingAt: day(11, 1), count: 12, calculator: calculator)
        XCTAssertEqual(report.months.count, 3, "September, October and an empty November")
        XCTAssertEqual(report.months[1].net, 1750)
        XCTAssertEqual(report.totalSpending, 400, "Card repayments aren't spending")
        XCTAssertEqual(report.averageSpending, 200, "The empty month doesn't pull the average down")
        XCTAssertEqual(report.savingsRate ?? 0, 0.9, accuracy: 0.001)
        XCTAssertTrue(report.csv(calendar: calendar).contains("2026-10,2000,250,1750"))
    }

    func testCategoryTrendsBreakDownIntoSubcategories() {
        let transactions = [
            tx(day(9, 5), "PRET", "-10", "Eating out", sub: "Coffee"),
            tx(day(10, 5), "PRET", "-30", "Eating out", sub: "Coffee"),
            tx(day(10, 6), "DISHOOM", "-60", "Eating out", sub: "Restaurant"),
            tx(day(10, 7), "CAFE", "-5", "Eating out"),
            tx(day(10, 8), "TESCO", "-40", "Groceries"),
        ]
        let report = CategoryTrendsReport.make(transactions, endingAt: day(10, 1), count: 2, calculator: calculator)
        XCTAssertEqual(report.categories.map(\.category.name), ["Eating out", "Groceries"])
        let eatingOut = report.categories[0]
        XCTAssertEqual(eatingOut.category.monthly, [10, 95])
        XCTAssertEqual(eatingOut.subcategories.map(\.name), ["Restaurant", "Coffee", "Other"])
        XCTAssertEqual(eatingOut.category.latestChange ?? 0, 8.5, accuracy: 0.001)
        XCTAssertTrue(report.categories[1].subcategories.isEmpty, "A lone Other line just repeats the category")
        XCTAssertTrue(report.csv(calendar: calendar).contains("Eating out,Coffee,10,30,40"))
    }

    func testTopShopsGroupBranchesAndCountRefunds() {
        let transactions = [
            tx(day(10, 1), "TESCO STORES 1234 LONDON", "-50", "Groceries"),
            tx(day(10, 3), "TESCO STORES 9876", "-30", "Groceries"),
            tx(day(10, 4), "TESCO STORES 9876", "10", "Groceries"),
            tx(day(10, 5), "BP 4432", "-60", "Transport", sub: "Fuel"),
            tx(day(10, 6), "ACME LTD", "2000", "Income"),
        ]
        let shops = TopShops.make(transactions, from: day(10, 1), to: day(10, 31), calculator: calculator)
        XCTAssertEqual(shops.map(\.name), ["Tesco Stores", "BP"])
        XCTAssertEqual(shops[0].total, 70, "The refund comes off")
        XCTAssertEqual(shops[0].visits, 2)
        XCTAssertEqual(shops[0].averageVisit, 35)
        XCTAssertEqual(TopShops.make(transactions, from: day(10, 1), to: day(10, 31), category: "Transport", subcategory: "Fuel", calculator: calculator).map(\.name), ["BP"])
        XCTAssertEqual(TopShops.make(transactions, from: day(10, 1), to: day(10, 31), limit: 1, calculator: calculator).count, 1)
    }

    func testReceiptSplitsCountInTheirCategories() {
        var shop = tx(day(10, 2), "TESCO", "-50", "Groceries", sub: "Supermarket")
        shop.splits = [TransactionSplit(label: "Food", category: "Groceries", amount: 30), TransactionSplit(label: "Socks", category: "Shopping", amount: 20)]
        let report = CategoryTrendsReport.make([shop], endingAt: day(10, 1), count: 1, calculator: calculator)
        XCTAssertEqual(report.categories.map(\.category.total), [30, 20])
        XCTAssertTrue(report.categories.allSatisfy { $0.subcategories.isEmpty }, "Splits have no sub-category")
    }

    func testYearInReview() {
        let transactions = [
            tx(day(3, 1), "ACME LTD", "3000", "Income"),
            tx(day(3, 2), "TESCO", "-100", "Groceries"),
            tx(day(3, 9), "TESCO", "-100", "Groceries"),
            tx(day(7, 2), "BRITISH AIRWAYS", "-800", "Travel"),
            tx(day(7, 4), "AMEX", "-800", "Card payment"),
            tx(day(5, 2), "TESCO", "-50", "Groceries", ),
            tx(day(5, 2, year: 2025), "TESCO", "-500", "Groceries"),
            tx(day(1, 2, year: 2027), "TESCO", "-70", "Groceries"),
        ]
        let review = YearInReview.make(transactions, year: 2026, calculator: calculator)
        XCTAssertEqual(review.cashFlow.totalSpending, 1050)
        XCTAssertEqual(review.cashFlow.totalIncome, 3000)
        XCTAssertEqual(review.spendingChange, 550)
        XCTAssertEqual(review.topCategories.first?.category, "Travel")
        XCTAssertEqual(review.mostVisited?.name, "Tesco")
        XCTAssertEqual(review.mostVisited?.visits, 3)
        XCTAssertEqual(review.biggestPurchase?.merchant, "BRITISH AIRWAYS")
        XCTAssertEqual(review.payments, 4)
        XCTAssertEqual(calendar.component(.month, from: review.busiestMonth!.month), 7)
        XCTAssertEqual(calendar.component(.month, from: review.quietestMonth!.month), 5)
        XCTAssertEqual(YearInReview.years(in: transactions, calendar: calendar), [2027, 2026, 2025])
    }

    func testReadableNames() {
        XCTAssertEqual(Reports.readableName("TESCO STORES"), "Tesco Stores")
        XCTAssertEqual(Reports.readableName("M&S SIMPLY"), "M&S Simply")
        XCTAssertEqual(Reports.readableName("BP"), "BP")
        XCTAssertEqual(Reports.readableName("TFL TRAVEL"), "TFL Travel")
    }
}
