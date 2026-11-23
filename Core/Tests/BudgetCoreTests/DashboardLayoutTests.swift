import XCTest
@testable import BudgetCore

final class DashboardLayoutTests: XCTestCase {
    func testStandardLayoutFillsEveryRowExactly() {
        for row in DashboardGrid.rows(DashboardLayout.standard.items) {
            XCTAssertEqual(row.map(\.size.columns).reduce(0, +), 12, "\(row.map(\.kind))")
        }
    }

    func testEachWidgetAppearsOnce() {
        var layout = DashboardLayout.standard
        layout.add(.pace)
        XCTAssertEqual(layout.items.filter { $0.kind == .pace }.count, 1)
        let doubled = DashboardLayout(items: [.init(kind: .bills), .init(kind: .bills, size: .medium)])
        XCTAssertEqual(doubled.items.count, 1)
    }

    func testAddRemoveAndHidden() {
        var layout = DashboardLayout.standard
        XCTAssertEqual(layout.hidden, [.netWorth])
        layout.add(.netWorth)
        XCTAssertEqual(layout.items.last?.kind, .netWorth)
        XCTAssertTrue(layout.hidden.isEmpty)
        layout.remove(.activity)
        XCTAssertEqual(layout.hidden, [.activity])
    }

    func testMoveOntoTargetPutsItInThatPlace() {
        var layout = DashboardLayout.standard
        layout.move(.activity, onto: .spend)
        XCTAssertEqual(layout.items.first?.kind, .activity)
        layout.move(.activity, onto: .nextDays)
        // Dropping on a widget further along takes that widget's place, so it moves up one.
        XCTAssertEqual(layout.items.firstIndex { $0.kind == .activity }, layout.items.firstIndex { $0.kind == .nextDays }.map { $0 + 1 })
        XCTAssertEqual(layout.items.count, DashboardLayout.standard.items.count)
    }

    func testNudgeStopsAtTheEnds() {
        var layout = DashboardLayout.standard
        XCTAssertFalse(layout.canNudge(.spend, by: -1))
        layout.nudge(.spend, by: -1)
        XCTAssertEqual(layout.items.first?.kind, .spend)
        layout.nudge(.spend, by: 1)
        XCTAssertEqual(layout.items[1].kind, .spend)
        XCTAssertTrue(layout.canNudge(.spend, by: 1))
    }

    func testTilesOnlyTakeSmallOrMedium() {
        var layout = DashboardLayout.standard
        layout.resize(.bills, to: .full)
        XCTAssertEqual(layout.items.first { $0.kind == .bills }?.size, .small)
        layout.resize(.bills, to: .medium)
        XCTAssertEqual(layout.items.first { $0.kind == .bills }?.size, .medium)
        layout.resize(.pace, to: .wide)
        XCTAssertEqual(layout.items.first { $0.kind == .pace }?.size, .wide)
    }

    func testSavedLayoutRoundTripsAndSurvivesUnknownWidgets() throws {
        var layout = DashboardLayout.standard
        layout.remove(.nextDays)
        layout.resize(.pace, to: .wide)
        XCTAssertEqual(DashboardLayout.decoded(from: layout.encoded()), layout)

        let future = Data(#"{"items":[{"kind":"hologram","size":"small"},{"kind":"bills","size":"huge"},{"kind":"pace"}]}"#.utf8)
        let read = DashboardLayout.decoded(from: future)
        XCTAssertEqual(read.items.map(\.kind), [.bills, .pace])
        XCTAssertEqual(read.items.first?.size, .small)
    }

    func testUnreadableDataGivesTheStandardLayout() {
        XCTAssertEqual(DashboardLayout.decoded(from: nil), .standard)
        XCTAssertEqual(DashboardLayout.decoded(from: Data("nope".utf8)), .standard)
    }

    func testNarrowWindowsDoubleTheSpans() {
        let rows = DashboardGrid.rows(DashboardLayout.standard.items, scale: 2)
        XCTAssertTrue(rows.allSatisfy { $0.map { min($0.size.columns * 2, 12) }.reduce(0, +) <= 12 })
    }
}
