import XCTest
@testable import BudgetCore

final class RecurringTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: 12))! }

    private func tx(_ date: Date, _ merchant: String, _ amount: String, _ category: String = "Bills & utilities") -> BankTransaction {
        BankTransaction(date: date, merchant: merchant, amount: money(amount), category: category, fingerprint: UUID().uuidString)
    }

    func testMonthlyBillsWithChangingReferences() {
        let rows = [tx(day(8, 19), "Card Transaction 3531 19AUG26 SPOTIFY LIMITED LONDON GB", "-21.99", "Subscriptions"),
                    tx(day(9, 19), "Card Transaction 3531 19SEP26 SPOTIFY P470C86A2A LONDON GB", "-21.99", "Subscriptions"),
                    tx(day(10, 20), "Card Transaction 3531 19OCT26 SPOTIFY P483199740 LONDON GB", "-21.99", "Subscriptions"),
                    tx(day(8, 13), "DD OCTOPUS ENERGY", "-180.00"), tx(day(9, 15), "DD OCTOPUS ENERGY", "-196.40"), tx(day(10, 13), "DD OCTOPUS ENERGY", "-211.51"),
                    tx(day(10, 25), "TESCO", "-5")]
        let found = RecurringDetector.detect(rows, calendar: calendar)
        XCTAssertEqual(found.map(\.name), ["Octopus Energy", "Spotify"])
        XCTAssertEqual(found.first?.amount, money("211.51"), "The latest amount")
        XCTAssertEqual(found.first?.period, .monthly)
        XCTAssertEqual(calendar.component(.day, from: found.first!.nextDate), 13)
    }

    func testDirectDebitsNeedOnlyTwoAndWeeklyStandingOrders() {
        let rows = [tx(day(9, 1), "DD AVIVA", "-176.62"), tx(day(10, 1), "DD AVIVA", "-176.62"),
                    tx(day(9, 1), "AMAZON", "-20", "Shopping"), tx(day(10, 1), "AMAZON", "-20", "Shopping")]
            + (0..<5).map { tx(calendar.date(byAdding: .day, value: 7 * $0, to: day(9, 4))!, "SO POCKET MONEY", "-100", "Family") }
        let found = RecurringDetector.detect(rows, calendar: calendar)
        XCTAssertEqual(Set(found.map(\.name)), ["Aviva", "Pocket Money"], "Two Amazon orders a month apart aren't a bill")
        XCTAssertEqual(found.first { $0.name == "Pocket Money" }?.period, .weekly)
    }

    func testShoppingStoppedSeriesAndTransfersAreLeftOut() {
        let rows = [tx(day(8, 3), "TESCO", "-40", "Groceries"), tx(day(8, 9), "TESCO", "-95", "Groceries"), tx(day(8, 30), "TESCO", "-12", "Groceries"),
                    tx(day(5, 1), "DD GYM", "-30"), tx(day(6, 1), "DD GYM", "-30"), tx(day(7, 1), "DD GYM", "-30"),
                    tx(day(8, 1), "DD AMEX", "-500", "Card payment"), tx(day(9, 1), "DD AMEX", "-400", "Card payment"), tx(day(10, 1), "DD AMEX", "-450", "Card payment"),
                    tx(day(10, 20), "SHOP", "-1", "Shopping")]
        XCTAssertTrue(RecurringDetector.detect(rows, calendar: calendar).isEmpty)
    }

    func testTwoPlansWithOnePayeeAreSplitByAmount() {
        let rows = [9, 10, 11].flatMap { month in [tx(day(month, 5), "VIS INT'L 001 APPLE.COM/BILL", "-9.99", "Subscriptions"),
                                                   tx(day(month, 12), "VIS INT'L 002 APPLE.COM/BILL", "-0.99", "Subscriptions")] }
        let found = RecurringDetector.detect(rows, calendar: calendar)
        XCTAssertEqual(found.map(\.amount).sorted(), [money("0.99"), money("9.99")])
        XCTAssertNotEqual(found[0].id, found[1].id)
        XCTAssertEqual(RecurringDetector.detect(rows, calendar: calendar).map(\.id), found.map(\.id), "Ids stay the same")
    }
}
