import XCTest
@testable import BudgetCore

final class ProductCoverTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    private func day(_ d: Int, _ m: Int = 11, _ y: Int = 2026) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }

    func testReturnWindowClosingIsUrgentWarrantyIsNot() {
        let watch = CoverWatch(calendar: calendar)
        let headphones = ProductCover(item: "Headphones", shop: "John Lewis", purchased: day(1), returnBy: day(10), warrantyEnds: day(1, 11, 2028))
        XCTAssertNil(watch.urgency(headphones, now: day(1)))
        XCTAssertEqual(watch.urgency(headphones, now: day(5)), .returnBy(day(10), days: 5))
        XCTAssertEqual(watch.urgency(headphones, now: day(8))?.isUrgent, true)
        var returned = headphones
        returned.returned = true
        XCTAssertNil(watch.urgency(returned, now: day(8)))
        XCTAssertEqual(watch.urgency(headphones, now: day(15, 10, 2028)), .warrantyEnds(day(1, 11, 2028), days: 17))
    }

    func testActiveListsSoonestFirstAndDropsExpired() {
        let watch = CoverWatch(calendar: calendar)
        let a = ProductCover(item: "Kettle", shop: "Argos", purchased: day(1), returnBy: day(20))
        let b = ProductCover(item: "Shoes", shop: "Clarks", purchased: day(1), returnBy: day(12))
        let old = ProductCover(item: "Lamp", shop: "IKEA", purchased: day(1, 1), returnBy: day(1, 2))
        XCTAssertEqual(watch.active([a, b, old], now: day(5)).map(\.item), ["Shoes", "Kettle"])
    }

    func testRemindersReuseTheContractPlanner() {
        let planner = ReminderPlanner(calendar: calendar)
        let cover = ProductCover(item: "Drill", shop: "B&Q", purchased: day(1), returnBy: day(20), warrantyEnds: day(1, 11, 2027))
        let reminders = planner.reminders(for: [cover], now: day(2))
        XCTAssertEqual(reminders.map(\.kind), [.returnBy, .warrantyEnds])
        XCTAssertEqual(calendar.component(.day, from: reminders[0].fireDate), 17)
        XCTAssertEqual(calendar.component(.hour, from: reminders[0].fireDate), 9)
        XCTAssertEqual(reminders[0].identifier, "\(cover.id.uuidString).returnBy")
        XCTAssertTrue(planner.reminders(for: [cover], now: day(19)).allSatisfy { $0.kind == .warrantyEnds })
    }
}
