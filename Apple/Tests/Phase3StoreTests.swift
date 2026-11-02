import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class Phase3StoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let csv = "Date,Description,Amount\r\n01/10/2026,TESCO STORES 3297,-12.40\r\n02/10/2026,JOE BLOGGS LTD,-5.00\r\n03/10/2026,NETFLIX.COM,-10.99\r\n"

    func testImportFillsInCategories() throws {
        let store = BudgetStore(folder: folder)
        let result = try store.previewImport(text: csv, fileName: "october.csv", mapping: nil)
        XCTAssertEqual(result.newTransactions.map(\.category), ["Groceries", "Uncategorised", "Subscriptions"])
    }

    func testImportUsesWhatYouChoseBefore() throws {
        let store = BudgetStore(folder: folder)
        store.transactions = [BankTransaction(date: Date(), merchant: "TESCO STORES 1111", amount: -3, category: "Family", fingerprint: "old")]
        let result = try store.previewImport(text: csv, fileName: "october.csv", mapping: nil)
        XCTAssertEqual(result.newTransactions.first?.category, "Family")
    }
}
