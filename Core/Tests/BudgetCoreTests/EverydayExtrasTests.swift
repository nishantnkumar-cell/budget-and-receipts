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
