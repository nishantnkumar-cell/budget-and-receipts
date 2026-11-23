#if os(macOS)
import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class DashboardLayoutStoreTests: XCTestCase {
    func testLayoutIsSavedAndReadBack() throws {
        let suite = "dashboard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DashboardLayoutStore(defaults: defaults)
        XCTAssertEqual(first.layout, .standard)
        first.layout.remove(.nextDays)
        first.layout.add(.netWorth)
        first.layout.resize(.pace, to: .wide)

        let second = DashboardLayoutStore(defaults: defaults)
        XCTAssertEqual(second.layout, first.layout)
        XCTAssertFalse(second.layout.contains(.nextDays))
    }
}
#endif
