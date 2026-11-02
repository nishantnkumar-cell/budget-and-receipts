import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class Phase1FeatureTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testReceiptImageIsKeptAndFound() throws {
        let images = ReceiptImageStore(dataFolder: folder)
        let name = try images.save(Data([0xFF, 0xD8, 0xFF]), fileExtension: "JPG")
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertNotNil(images.url(for: name))
        XCTAssertNil(images.url(for: "missing.jpg"))
        XCTAssertNil(images.url(for: ""))
    }

    func testReceiptImagePathCannotEscapeTheFolder() throws {
        let images = ReceiptImageStore(dataFolder: folder)
        let name = try images.save(Data([1]))
        XCTAssertEqual(images.url(for: "../../\(name)")?.deletingLastPathComponent().standardizedFileURL, images.folder.standardizedFileURL)
    }

    func testSettingsPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let settings = AppSettings(defaults: defaults)
        settings.currencyCode = "EUR"
        settings.appLockEnabled = true
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.currencyCode, "EUR")
        XCTAssertTrue(reloaded.appLockEnabled)
        XCTAssertFalse(reloaded.remindersEnabled)
    }

    func testRolloverSettingIsKeptWhenLimitChanges() {
        let store = BudgetStore(folder: folder)
        store.setBudget(category: "Groceries", limit: 300, month: store.selectedMonth, rollover: true)
        store.setBudget(category: "Groceries", limit: 320, month: store.selectedMonth)
        XCTAssertEqual(store.budgets.count, 1)
        XCTAssertEqual(store.budgets[0].rollover, true)
        let next = Calendar.current.date(byAdding: .month, value: 1, to: store.selectedMonth)!
        store.setBudget(category: "Groceries", limit: 350, month: next)
        XCTAssertEqual(store.budgets.last?.rollover, true, "A new month's budget inherits rollover")
    }

    func testMonthReportPDFIsAPDF() {
        let report = MonthlyBudgetReport(month: Date(), income: 100, spending: 40, lines: [CategoryBudgetLine(category: "Groceries", limit: 50, spent: 40)])
        let data = MonthReportPDF.render(report)
        XCTAssertEqual(String(decoding: data.prefix(5), as: UTF8.self), "%PDF-")
    }
}
