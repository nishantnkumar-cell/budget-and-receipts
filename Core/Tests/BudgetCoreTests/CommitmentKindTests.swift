import XCTest
@testable import BudgetCore

final class CommitmentKindTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }

    private func item(_ name: String, kind: CommitmentKind? = nil, termEnds: Date? = nil, notice: Int? = nil) -> SubscriptionContract {
        var item = SubscriptionContract(vendor: name, category: .other, startDate: day(2026, 1, 1), billingPeriod: .monthly,
                                        nextPaymentDueDate: day(2026, 11, 20), expectedAmount: Decimal(string: "12.99")!, kind: kind)
        item.minimumTermEndDate = termEnds
        item.cancellationNoticeDays = notice
        return item
    }

    func testOlderItemsAreGuessedFromTheirTerm() {
        XCTAssertEqual(item("Netflix").resolvedKind, .subscription)
        XCTAssertEqual(item("Vodafone", termEnds: day(2027, 6, 1)).resolvedKind, .contract)
        XCTAssertEqual(item("Spotify", kind: .subscription, termEnds: day(2027, 6, 1)).resolvedKind, .subscription)
    }

    func testOldItemsWithoutKindStillDecode() throws {
        let saved = try JSONEncoder().encode(item("Netflix"))
        var object = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        object.removeValue(forKey: "kind")
        let decoded = try JSONDecoder().decode(SubscriptionContract.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.kind)
        XCTAssertEqual(decoded.expectedAmount, Decimal(string: "12.99"))
    }

    func testMonthsLeft() {
        let contract = item("EDF", kind: .contract, termEnds: day(2027, 5, 8))
        XCTAssertEqual(contract.monthsLeft(from: day(2026, 11, 8), calendar: calendar), 6)
        XCTAssertEqual(contract.monthsLeft(from: day(2027, 6, 1), calendar: calendar), 0)
        XCTAssertNil(item("Netflix").monthsLeft(from: day(2026, 11, 8)))
    }

    func testOnlyContractsFeedContractDates() {
        let planner = ComingUpPlanner(calendar: calendar)
        let now = day(2026, 11, 8)
        let phone = item("Vodafone", kind: .contract, termEnds: day(2026, 12, 20), notice: 30)
        var streaming = item("Netflix", kind: .subscription)
        streaming.renewalDate = day(2026, 12, 1)
        let dates = planner.contractDates([phone, streaming], from: now)
        XCTAssertEqual(dates.map(\.vendor), ["Vodafone", "Vodafone"])
        XCTAssertEqual(dates.map(\.kind), [.cancellationDeadline, .minimumTermEnds])
        XCTAssertEqual(dates.first?.date, day(2026, 11, 20))
        // Both still have payments.
        XCTAssertEqual(Set(planner.payments([phone, streaming], from: now).map(\.vendor)), ["Vodafone", "Netflix"])
    }

    func testRemovedBudgetEndsAnEarlierLimit() {
        let calculator = BudgetCalculator()
        let budgets = [
            MonthlyBudget(category: "Groceries", limit: 400, month: day(2026, 9, 1)),
            MonthlyBudget(category: "Groceries", limit: 0, month: day(2026, 11, 1), removed: true),
        ]
        XCTAssertEqual(calculator.budget(for: "Groceries", in: budgets, month: day(2026, 10, 15))?.limit, 400)
        XCTAssertNil(calculator.budget(for: "Groceries", in: budgets, month: day(2026, 11, 15)))
        XCTAssertNil(calculator.budget(for: "Groceries", in: budgets, month: day(2027, 1, 15)))
    }
}
