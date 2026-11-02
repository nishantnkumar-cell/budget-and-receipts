import XCTest
@testable import BudgetCore

final class NetWorthTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ d: Int = 15) -> Date { calendar.date(from: DateComponents(year: year, month: month, day: d, hour: 12))! }
    private var calculator: NetWorthCalculator { NetWorthCalculator(calendar: calendar) }

    private var house: WealthAccount { WealthAccount(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Home", kind: .property, owner: .shared, balances: [.init(date: day(2026, 1), amount: 500_000)]) }

    private var accounts: [WealthAccount] {
        [
            WealthAccount(name: "Current", kind: .cash, owner: .mine, balances: [.init(date: day(2026, 9), amount: 3_000), .init(date: day(2026, 10), amount: 4_000)]),
            WealthAccount(name: "Workplace pension", kind: .pension, owner: .partner, balances: [.init(date: day(2026, 10), amount: 80_000)]),
            house,
            WealthAccount(name: "Mortgage", kind: .mortgage, owner: .shared, balances: [.init(date: day(2026, 10), amount: 300_000)], repayment: .init(annualRate: money("0.045"), monthlyPayment: 1_800), propertyID: house.id),
            WealthAccount(name: "Credit card", kind: .creditCard, owner: .mine, balances: [.init(date: day(2026, 10), amount: 1_000)]),
        ]
    }

    func testPensionsAndPropertyCountAndDebtsSubtract() {
        XCTAssertEqual(calculator.total(accounts, on: day(2026, 10, 20)), 4_000 + 80_000 + 500_000 - 300_000 - 1_000)
    }

    func testValueOnADateUsesTheLatestBalanceBeforeIt() {
        XCTAssertEqual(accounts[0].value(on: day(2026, 9, 30)), 3_000)
        XCTAssertNil(accounts[0].value(on: day(2026, 8)))
    }

    func testReportGroups() {
        let groups = Dictionary(uniqueKeysWithValues: calculator.byGroup(accounts, on: day(2026, 10, 20)).map { ($0.group, $0.amount) })
        XCTAssertEqual(groups[.cash], 4_000)
        XCTAssertEqual(groups[.pensions], 80_000)
        XCTAssertEqual(groups[.mortgage], -300_000)
        XCTAssertEqual(groups[.otherDebts], -1_000)
        XCTAssertNil(groups[.investments])
    }

    func testByOwnerAndMyView() {
        let owners = calculator.byOwner(accounts, on: day(2026, 10, 20))
        XCTAssertEqual(owners[.shared], 200_000)
        XCTAssertEqual(owners[.mine], 3_000)
        let ledger = CoupleLedger(settings: CoupleSettings(partnerName: "Sara"))
        XCTAssertEqual(calculator.total(accounts, for: .me, ledger: ledger, on: day(2026, 10, 20)), 3_000 + 100_000)
    }

    func testTrendHasOnePointPerMonthSinceTheFirstBalance() {
        let trend = calculator.monthlyTrend(accounts, months: 12, now: day(2026, 11, 2))
        XCTAssertEqual(trend.count, 11, "January to November")
        XCTAssertEqual(trend.last?.total, calculator.total(accounts, on: day(2026, 11, 2)))
    }

    func testMortgagePayoffAndEquity() throws {
        let mortgage = accounts[3]
        let payoff = try XCTUnwrap(calculator.payoffDate(mortgage))
        let years = calendar.dateComponents([.year], from: day(2026, 10), to: payoff).year!
        XCTAssertTrue((19...21).contains(years), "About 20 years at £1,800 a month: \(years)")
        XCTAssertEqual(calculator.equity(of: house, accounts: accounts, on: day(2026, 10, 20)), 200_000)
        var tooSmall = mortgage
        tooSmall.repayment = .init(annualRate: money("0.045"), monthlyPayment: 500)
        XCTAssertNil(calculator.payoffDate(tooSmall), "Doesn't cover the interest")
    }

    func testStaleBalancesAskForAnUpdate() {
        XCTAssertTrue(accounts[0].needsUpdate(now: day(2026, 12, 1)))
        XCTAssertFalse(accounts[0].needsUpdate(now: day(2026, 10, 20)))
    }

    func testPartnersPhoneSeesOwnersFlipped() {
        let record = SyncRecord.records([accounts[1]], collection: "wealth", id: { $0.id.uuidString })[0]
        let flipped = try! SyncRecord.decoder().decode(WealthAccount.self, from: HouseholdPerspective.flipped(record).payload)
        XCTAssertEqual(flipped.owner, .mine)
    }
}
