import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class StatementImportStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let csv = "Date,Description,Amount\n01/10/2026,SALARY ACME LTD,2500.00\n03/10/2026,TESCO STORES,-45.67\n"

    func testImportThenReimportAddsNothing() throws {
        let store = BudgetStore(folder: folder)
        let preview = try store.previewImport(text: csv, fileName: "october.csv", mapping: nil)
        XCTAssertEqual(preview.newTransactions.count, 2)
        store.commitImport(preview, fileName: "october.csv")

        let reopened = BudgetStore(folder: folder)
        XCTAssertEqual(reopened.transactions.count, 2)
        XCTAssertEqual(reopened.imports.first?.transactionCount, 2)
        let again = try reopened.previewImport(text: csv, fileName: "october.csv", mapping: nil)
        XCTAssertTrue(again.newTransactions.isEmpty)
        XCTAssertEqual(again.duplicates.count, 2)
    }

    func testPreviewChangesNothing() throws {
        let store = BudgetStore(folder: folder)
        _ = try store.previewImport(text: csv, fileName: "october.csv", mapping: nil)
        XCTAssertTrue(store.transactions.isEmpty)
    }

    func testUnknownColumnsAskForMapping() {
        let store = BudgetStore(folder: folder)
        XCTAssertThrowsError(try store.previewImport(text: "A,B,C\n1,2,3\n", fileName: "x.csv", mapping: nil))
    }

    func testOverviewTotalsFollowTheSelectedMonth() throws {
        let store = BudgetStore(folder: folder)
        store.commitImport(try store.previewImport(text: csv, fileName: "october.csv", mapping: nil), fileName: "october.csv")
        store.transactions = store.transactions.map {
            var transaction = $0
            transaction.category = $0.amount > 0 ? "Income" : "Groceries"
            return transaction
        }
        var components = DateComponents(year: 2026, month: 10, day: 15)
        store.selectedMonth = Calendar.current.date(from: components)!
        XCTAssertEqual(store.spending, Decimal(string: "45.67"))
        XCTAssertEqual(store.income, Decimal(string: "2500.00"))

        components.month = 11
        store.selectedMonth = Calendar.current.date(from: components)!
        XCTAssertEqual(store.spending, 0)
        XCTAssertEqual(store.income, 0)
    }

    func testBudgetSetForSelectedMonthShowsInReport() {
        let store = BudgetStore(folder: folder)
        store.setBudget(category: "Groceries", limit: 300, month: store.selectedMonth)
        XCTAssertEqual(store.monthReport.lines.first { $0.category == "Groceries" }?.limit, 300)
        store.moveMonth(by: 1)
        XCTAssertEqual(store.monthReport.lines.first { $0.category == "Groceries" }?.limit, 300, "Budgets carry forward")
    }
}
