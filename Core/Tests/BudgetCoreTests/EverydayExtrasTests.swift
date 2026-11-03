import XCTest
@testable import BudgetCore

final class EverydayExtrasTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ d: Int, year: Int = 2026) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: d, hour: 12))! }

    func testYearlyBillsAreSpreadOverTheMonthsUntilDue() {
        let insurance = SubscriptionContract(vendor: "Car insurance", category: .insurance, startDate: day(1, 1), billingPeriod: .yearly, nextPaymentDueDate: day(5, 1, year: 2027), expectedAmount: 600)
        let netflix = SubscriptionContract(vendor: "Netflix", category: .streaming, startDate: day(1, 1), billingPeriod: .monthly, nextPaymentDueDate: day(11, 20), expectedAmount: 11)
        let plan = SetAside.plan([insurance, netflix], now: day(11, 1), calendar: calendar)
        XCTAssertEqual(plan.map(\.vendor), ["Car insurance"], "Monthly bills need no set-aside")
        XCTAssertEqual(plan.first?.monthly, 100, "£600 over 6 months")
    }

    func testMonthReview() {
        let tx = { (month: Int, amount: String, category: String) in
            BankTransaction(date: self.day(month, 10), merchant: category, amount: money(amount), category: category, fingerprint: UUID().uuidString)
        }
        let transactions = [tx(10, "-300", "Groceries"), tx(10, "-80", "Eating out"), tx(10, "2500", "Income"),
                            tx(9, "-250", "Groceries"), tx(9, "-20", "Eating out"), tx(10, "-500", "Card payment")]
        let review = MonthReview.make(transactions, budgets: [MonthlyBudget(category: "Eating out", limit: 50, month: day(10, 1))], month: day(10, 1), calculator: BudgetCalculator(calendar: calendar))
        XCTAssertEqual(review.spending, 380)
        XCTAssertEqual(review.spendingChange, 110)
        XCTAssertEqual(review.topCategories.first?.category, "Groceries")
        XCTAssertEqual(review.topCategories.first?.change, 50)
        XCTAssertEqual(review.overBudget, ["Eating out"])
        XCTAssertEqual(review.biggestPurchase?.amount, -300, "A card payment is a transfer, not a purchase")
    }

    func testOneCorrectionFindsTheOthers() {
        let all = [
            BankTransaction(date: day(10, 1), merchant: "BIKANERVALA HOUNSLOW", amount: -16, fingerprint: "a"),
            BankTransaction(date: day(10, 8), merchant: "BIKANERVALA HOUNSLOW", amount: -18, fingerprint: "b"),
            BankTransaction(date: day(10, 9), merchant: "BIKANERVALA HOUNSLOW", amount: -9, category: "Eating out", fingerprint: "c"),
        ]
        XCTAssertEqual(Categoriser.similarUncategorised(to: all[0], in: all).map(\.fingerprint), ["b"])
    }

    func testNotesFlipTheirAuthor() {
        let note = TransactionNote(transactionID: "t", author: .me, text: "Dinner with your parents")
        let record = SyncRecord.records([note], collection: "notes", id: { $0.id.uuidString })[0]
        XCTAssertEqual(try SyncRecord.decoder().decode(TransactionNote.self, from: HouseholdPerspective.flipped(record).payload).author, .partner)
    }
}

final class PaydayTagsForecastTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: 12))! }

    func testPaydayMonthRunsFromTheStartDay() {
        let calculator = BudgetCalculator(calendar: calendar, monthStartDay: 25)
        XCTAssertTrue(calculator.isInMonth(day(10, 25), day(11, 1)), "25 October is in November's budget")
        XCTAssertTrue(calculator.isInMonth(day(11, 24), day(11, 1)))
        XCTAssertFalse(calculator.isInMonth(day(11, 25), day(11, 1)), "25 November starts December")
        XCTAssertTrue(BudgetCalculator(calendar: calendar).isInMonth(day(11, 25), day(11, 1)), "Calendar months unchanged")
    }

    func testExpenseReportForATag() {
        var hotel = BankTransaction(date: day(10, 5), merchant: "HOTEL", amount: -200, category: "Travel", fingerprint: "h")
        hotel.tags = ["Work trip"]
        var taxi = BankTransaction(date: day(10, 6), merchant: "UBER", amount: -25, category: "Transport", fingerprint: "t")
        taxi.tags = ["work trip"]
        let coffee = BankTransaction(date: day(10, 6), merchant: "COSTA", amount: -3, category: "Eating out", fingerprint: "c")
        let report = ExpenseReport.make([hotel, taxi, coffee], from: day(10, 1), to: day(10, 31), tag: "Work trip", calculator: BudgetCalculator(calendar: calendar))
        XCTAssertEqual(report.transactions.count, 2)
        XCTAssertEqual(report.total, 225)
        XCTAssertEqual(report.byCategory.first?.category, "Travel")
        XCTAssertTrue(report.csv(calendar: calendar).hasSuffix("Total,225\r\n"))
    }

    func testBalanceForecast() {
        let history = (1...90).map { BankTransaction(date: calendar.date(byAdding: .day, value: -$0, to: day(11, 11))!, merchant: "SHOP", amount: -10, category: "Groceries", fingerprint: "\($0)") }
        let rent = UpcomingItem(contractID: UUID(), vendor: "Rent", kind: .payment, date: day(11, 25), amount: 1_000, currency: "GBP", billingPeriod: .monthly)
        let forecast = BalanceForecast.make(balance: 1_500, transactions: history, upcomingBills: [rent], expectedIncome: [(day(11, 28), 2_000)], now: day(11, 11), calendar: calendar)
        XCTAssertEqual(forecast?.everydaySpending, 200, "£10 a day for the 20 days left")
        XCTAssertEqual(forecast?.endOfMonth, 1_500 - 1_000 - 200 + 2_000)
        XCTAssertEqual(forecast?.goesOverdrawn, false)
    }
    func testForecastDoesntCountBillsTwiceOrAssume90Days() {
        // 30 days of statements: £10 a day of shopping, plus rent paid last month.
        var history = (1...30).map { BankTransaction(date: calendar.date(byAdding: .day, value: -$0, to: day(11, 11))!, merchant: "SHOP", amount: -10, category: "Groceries", fingerprint: "\($0)") }
        history.append(BankTransaction(date: day(10, 25), merchant: "RENT LANDLORD", amount: -1_000, category: "Housing", fingerprint: "rent"))
        let rent = UpcomingItem(contractID: UUID(), vendor: "Rent", kind: .payment, date: day(11, 25), amount: 1_000, currency: "GBP", billingPeriod: .monthly)
        let forecast = BalanceForecast.make(balance: 1_500, transactions: history, upcomingBills: [rent], isBill: { $0.merchant.contains("RENT") }, now: day(11, 11), calendar: calendar)
        XCTAssertEqual(forecast?.everydaySpending, 200, "£10 a day over the 30 days held, for the 20 days left; rent only once")
        XCTAssertEqual(forecast?.endOfMonth, 1_500 - 1_000 - 200)
    }
}
