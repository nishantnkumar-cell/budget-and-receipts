import XCTest
@testable import BudgetCore

final class ComingUpTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: 9))! }
    private var planner: ComingUpPlanner { ComingUpPlanner(calendar: calendar) }

    private func contract(_ vendor: String, due: Date, period: BillingPeriod = .monthly, amount: String = "10.00", status: SubscriptionStatus = .active) -> SubscriptionContract {
        SubscriptionContract(vendor: vendor, category: .other, startDate: day(1, 1), billingPeriod: period, nextPaymentDueDate: due, expectedAmount: money(amount), status: status)
    }

    func testNextPaymentsInDateOrder() {
        let items = planner.payments([contract("Netflix", due: day(11, 20)), contract("Rent", due: day(11, 5), amount: "1200.00")], from: day(11, 2))
        XCTAssertEqual(items.map(\.vendor), ["Rent", "Netflix"])
        XCTAssertEqual(planner.totalDue(items), ["GBP": money("1210.00")])
    }

    func testAPassedDueDateRollsForwardInsteadOfVanishing() {
        // Due on 25 October and never marked paid: the next real payment is 25 November.
        let items = planner.payments([contract("Gym", due: day(10, 25))], from: day(11, 2))
        XCTAssertEqual(items.map(\.date), [day(11, 25)])
    }

    func testWeeklyBillsShowEachWeek() {
        XCTAssertEqual(planner.payments([contract("Veg box", due: day(11, 3), period: .weekly)], from: day(11, 2)).count, 5)
    }

    func testPausedAndCancelledAreLeftOut() {
        XCTAssertTrue(planner.payments([contract("Old", due: day(11, 5), status: .cancelled), contract("Paused", due: day(11, 5), status: .paused)], from: day(11, 2)).isEmpty)
    }

    func testContractDatesIncludeTheLastDayToCancel() {
        var broadband = contract("BT Broadband", due: day(11, 10))
        broadband.renewalDate = day(12, 31)
        broadband.cancellationNoticeDays = 30
        broadband.pricing = .introductory
        broadband.fixedPriceEndDate = day(12, 31)
        var phone = contract("EE", due: day(11, 12))
        phone.minimumTermEndDate = day(11, 30)
        let items = planner.contractDates([broadband, phone], from: day(11, 2))
        XCTAssertEqual(items.map(\.kind), [.minimumTermEnds, .cancellationDeadline, .fixedPriceEnds, .renewal])
        XCTAssertEqual(items[1].date, day(12, 1))
        XCTAssertNil(items[0].amount)
    }

    func testContractDatesBeyond90DaysWait() {
        var insurance = contract("Car insurance", due: day(11, 10))
        insurance.renewalDate = day(4, 1).addingTimeInterval(365 * 86400)
        XCTAssertTrue(planner.contractDates([insurance], from: day(11, 2)).isEmpty)
    }
}
