import XCTest
@testable import BudgetCore

final class HouseholdReportsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ d: Int, year: Int = 2026) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: d, hour: 12))! }

    private func tx(_ date: Date, _ merchant: String, _ amount: String, _ category: String, owner: MoneyOwner? = nil) -> BankTransaction {
        var transaction = BankTransaction(date: date, merchant: merchant, amount: money(amount), category: category, fingerprint: UUID().uuidString)
        transaction.owner = owner
        return transaction
    }

    func testOwnerSpendingSplitsByWhoseMoneyItWas() {
        var groceries = tx(day(10, 3), "TESCO", "-100", "Groceries", owner: .shared)
        groceries.splits = [
            TransactionSplit(label: "Food", category: "Groceries", amount: 70),
            TransactionSplit(label: "Make-up", category: "Personal care", amount: 30, owner: .partner),
        ]
        let transactions = [
            groceries,
            tx(day(10, 5), "NETFLIX", "-10", "Subscriptions", owner: .mine),
            tx(day(10, 6), "ZARA", "-50", "Shopping", owner: .partner),
            tx(day(10, 7), "ZARA", "20", "Shopping", owner: .partner),
            tx(day(10, 8), "AMEX", "-900", "Card payment", owner: .mine),
            tx(day(10, 1), "ACME LTD", "2000", "Income", owner: .mine),
            tx(day(11, 2), "NETFLIX", "-10", "Subscriptions", owner: .mine),
        ]
        let ledger = CoupleLedger(settings: CoupleSettings(partnerName: "Sam"))
        let split = OwnerSpending.make(transactions, from: day(10, 1), to: day(10, 31), ledger: ledger, calculator: BudgetCalculator(calendar: calendar))
        XCTAssertEqual(split.shared, 70)
        XCTAssertEqual(split.partner, 60, "The split's own owner wins, and the refund comes off")
        XCTAssertEqual(split.mine, 10, "Card repayments, income and other months don't count")
        XCTAssertEqual(split.total, 140)
        XCTAssertEqual(split.fraction(.shared), 0.5, accuracy: 0.001)
    }

    func testNetWorthReportKeepsPensionsAndPropertyApart() {
        let house = WealthAccount(name: "Home", kind: .property, owner: .shared, balances: [.init(date: day(1, 10), amount: 300_000)])
        let accounts = [
            WealthAccount(name: "Current", kind: .cash, owner: .mine, balances: [.init(date: day(1, 10), amount: 2_000), .init(date: day(6, 10), amount: 5_000)]),
            WealthAccount(name: "Workplace pension", kind: .pension, owner: .mine, balances: [.init(date: day(1, 10), amount: 40_000)]),
            WealthAccount(name: "Her pension", kind: .pension, owner: .partner, balances: [.init(date: day(1, 10), amount: 20_000)]),
            house,
            WealthAccount(name: "Mortgage", kind: .mortgage, owner: .shared, balances: [.init(date: day(1, 10), amount: 200_000)], propertyID: house.id),
            WealthAccount(name: "Amex", kind: .creditCard, owner: .mine, balances: [.init(date: day(1, 10), amount: 1_000)]),
        ]
        let together = NetWorthReport.make(accounts, months: 12, now: day(6, 20), calendar: calendar)
        XCTAssertEqual(together.points.count, 6, "January to June, nothing before the first value")
        XCTAssertEqual(together.pensions, 60_000)
        XCTAssertEqual(together.property, 300_000)
        XCTAssertEqual(together.mortgage, -200_000)
        XCTAssertEqual(together.homeEquity, 100_000)
        XCTAssertEqual(together.total, 164_000)
        XCTAssertEqual(together.excludingPensionsAndProperty, 4_000, "Cash less the card")
        XCTAssertEqual(together.change, 3_000)
        XCTAssertEqual(together.groups.map(\.group), [.cash, .pensions, .property, .mortgage, .otherDebts])
        XCTAssertTrue(together.csv(calendar: calendar).contains("2026-06,5000,60000,300000,-200000,-1000,164000,4000"))

        let ledger = CoupleLedger(settings: CoupleSettings(partnerName: "Sam"))
        let me = NetWorthReport.make(accounts, view: .me, ledger: ledger, months: 12, now: day(6, 20), calendar: calendar)
        XCTAssertEqual(me.pensions, 40_000, "Her pension isn't in my view")
        XCTAssertEqual(me.homeEquity, 50_000, "Half the shared home")
        XCTAssertEqual(me.total, 40_000 + 50_000 + 4_000)
    }

    func testNetWorthReportWithNoAccounts() {
        let report = NetWorthReport.make([], now: day(6, 20), calendar: calendar)
        XCTAssertTrue(report.points.isEmpty)
        XCTAssertEqual(report.total, 0)
        XCTAssertNil(report.change)
    }
}
