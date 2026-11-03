import XCTest
@testable import BudgetCore

final class EverydayInsightsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: 12))! }

    private func netflix(_ expected: String = "10.99") -> SubscriptionContract {
        SubscriptionContract(vendor: "Netflix", category: .streaming, startDate: day(1, 1), billingPeriod: .monthly, nextPaymentDueDate: day(11, 20), expectedAmount: money(expected))
    }

    private func paid(_ amount: String, _ month: Int) -> BankTransaction {
        BankTransaction(date: day(month, 20), merchant: "NETFLIX.COM", amount: money("-" + amount), fingerprint: "\(month)")
    }

    func testPriceRiseIsSpotted() {
        let rise = SubscriptionTracker().priceRise(for: netflix(), transactions: [paid("10.99", 9), paid("12.99", 10)])
        XCTAssertEqual(rise?.previous, money("10.99"))
        XCTAssertEqual(rise?.latest, money("12.99"))
        XCTAssertEqual(rise?.percent ?? 0, 0.182, accuracy: 0.001)
    }

    func testSmallWobblesAndDropsAreNotRises() {
        XCTAssertNil(SubscriptionTracker().priceRise(for: netflix(), transactions: [paid("10.99", 9), paid("11.05", 10)]))
        XCTAssertNil(SubscriptionTracker().priceRise(for: netflix(), transactions: [paid("10.99", 9), paid("8.99", 10)]))
    }

    func testFirstPaymentIsComparedWithTheExpectedPrice() {
        XCTAssertEqual(SubscriptionTracker().priceRise(for: netflix("9.99"), transactions: [paid("12.99", 10)])?.previous, money("9.99"))
    }

    func testSafeToSpendSharesWhatsLeftAfterBills() {
        let report = MonthlyBudgetReport(month: day(11, 1), income: 0, spending: 200, lines: [
            CategoryBudgetLine(category: "Groceries", limit: 400, spent: 200),
            CategoryBudgetLine(category: "Eating out", limit: nil, spent: 50),
        ])
        let bill = UpcomingItem(contractID: UUID(), vendor: "Netflix", kind: .payment, date: day(11, 20), amount: money("10.99"), currency: "GBP", billingPeriod: .monthly)
        let nextMonth = UpcomingItem(contractID: UUID(), vendor: "Rent", kind: .payment, date: day(12, 1), amount: 1000, currency: "GBP", billingPeriod: .monthly)
        let safe = SafeToSpend.calculate(report: report, upcomingBills: [bill, nextMonth], today: day(11, 11), calendar: calendar)
        XCTAssertEqual(safe?.daysLeft, 20, "11 to 30 November")
        XCTAssertEqual(safe?.billsStillToCome, money("10.99"))
        XCTAssertEqual(safe?.today, money("9.45"), "(200 - 10.99) / 20, rounded down")
    }

    func testNoSafeToSpendWithoutBudgetsOrForAnotherMonth() {
        let none = MonthlyBudgetReport(month: day(11, 1), income: 0, spending: 0, lines: [])
        XCTAssertNil(SafeToSpend.calculate(report: none, upcomingBills: [], today: day(11, 11), calendar: calendar))
        let october = MonthlyBudgetReport(month: day(10, 1), income: 0, spending: 0, lines: [CategoryBudgetLine(category: "Groceries", limit: 100, spent: 0)])
        XCTAssertNil(SafeToSpend.calculate(report: october, upcomingBills: [], today: day(11, 11), calendar: calendar))
    }

    func testDuplicateReceiptWarnings() {
        let receipt = ReceiptDraftEditor(merchant: "TESCO", purchaseDate: day(11, 1), receiptTotal: money("12.40"))
        let waiting = PendingReceipt(editor: ReceiptDraftEditor(merchant: "Tesco", purchaseDate: day(11, 2), receiptTotal: money("12.40")))
        XCTAssertNotNil(ReceiptDuplicates.match(receipt, pending: [waiting], transactions: [], calendar: calendar))
        let different = PendingReceipt(editor: ReceiptDraftEditor(merchant: "Tesco", purchaseDate: day(11, 5), receiptTotal: money("12.40")))
        XCTAssertNil(ReceiptDuplicates.match(receipt, pending: [different], transactions: [], calendar: calendar), "Same shop and total, days apart: a new shop")
    }

    func testJointAccountMakesItsPaymentsShared() {
        let joint = UUID()
        var ledger = CoupleLedger(settings: CoupleSettings(partnerName: "Sara"))
        ledger.accountOwners = [joint: .shared]
        var rent = BankTransaction(date: day(11, 1), merchant: "LANDLORD", amount: -1000, fingerprint: "r")
        rent.accountID = joint
        XCTAssertEqual(ledger.owner(of: rent), .shared)
        XCTAssertEqual(ledger.ownerSource(of: rent), .account(joint))
        rent.owner = .mine
        XCTAssertEqual(ledger.ownerSource(of: rent), .manual)
    }

    func testPaymentReminderFollowsTheContract() {
        var contract = netflix()
        let planner = ReminderPlanner(calendar: calendar)
        contract.remindDaysBefore = 0
        XCTAssertFalse(planner.reminders(for: contract, now: day(11, 1)).contains { $0.kind == .paymentDue })
        contract.remindDaysBefore = 5
        let reminder = planner.reminders(for: contract, now: day(11, 1)).first { $0.kind == .paymentDue }
        XCTAssertEqual(calendar.component(.day, from: reminder!.fireDate), 15)
    }
    func testSafeToSpendFollowsAPaydayMonth() {
        // A budget month from 25 October to 24 November, on 30 October.
        let period = DateInterval(start: calendar.startOfDay(for: day(10, 25)), end: calendar.startOfDay(for: day(11, 25)))
        let report = MonthlyBudgetReport(month: day(11, 1), income: 0, spending: 0, lines: [CategoryBudgetLine(category: "Groceries", limit: 260, spent: 0)])
        let safe = SafeToSpend.calculate(report: report, upcomingBills: [], today: day(10, 30), period: period, calendar: calendar)
        XCTAssertEqual(safe?.daysLeft, 26, "30 October to 24 November")
        XCTAssertEqual(safe?.today, 10)
    }
}
