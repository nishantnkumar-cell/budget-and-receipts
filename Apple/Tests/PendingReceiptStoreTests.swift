import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class PendingReceiptStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func day(_ d: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }

    private func receipt(_ total: String, _ d: Int) -> ReceiptDraftEditor {
        ReceiptDraftEditor(merchant: "TESCO", purchaseDate: day(d), receiptTotal: Decimal(string: total), items: [ReceiptLineItem(description: "Milk", total: Decimal(string: total)!, category: "Groceries", confidence: 1)])
    }

    func testReceiptWaitsThenMatchesWhenTheStatementArrives() throws {
        let store = BudgetStore(folder: folder)
        store.savePending(receipt("12.40", 9))
        XCTAssertEqual(BudgetStore(folder: folder).pendingReceipts.count, 1, "Saved across launches")

        // The payment posts four days later.
        let csv = "Date,Description,Amount\r\n13/10/2026,TESCO STORES 3297,-12.40\r\n13/10/2026,COSTA,-3.20\r\n"
        store.commitImport(try store.previewImport(text: csv, fileName: "october.csv", mapping: nil), fileName: "october.csv")

        XCTAssertTrue(store.pendingReceipts.isEmpty)
        let matched = try XCTUnwrap(store.transactions.first { $0.merchant == "TESCO STORES 3297" })
        XCTAssertEqual(matched.pendingSplitDraft?.receipt.reviewed, false, "Matched, but still waits for approval")
        XCTAssertTrue(matched.splits.isEmpty)
        XCTAssertTrue(store.needsReview.contains { $0.id == matched.id })
        XCTAssertTrue(store.status.contains("Matched 1 waiting receipt"))
    }

    func testUnsureMatchKeepsWaiting() throws {
        let store = BudgetStore(folder: folder)
        store.savePending(receipt("3.20", 9))
        let csv = "Date,Description,Amount\r\n09/10/2026,PRET,-3.20\r\n10/10/2026,COSTA,-3.20\r\n"
        store.commitImport(try store.previewImport(text: csv, fileName: "october.csv", mapping: nil), fileName: "october.csv")
        XCTAssertEqual(store.pendingReceipts.count, 1)
    }

    func testPickingAPaymentByHandAndDeleting() throws {
        let store = BudgetStore(folder: folder)
        store.transactions = [BankTransaction(date: day(9), merchant: "TESCO", amount: -15, fingerprint: "t")]
        store.savePending(receipt("12.40", 9))
        store.attachPending(store.pendingReceipts[0], to: store.transactions[0])
        XCTAssertTrue(store.pendingReceipts.isEmpty)
        XCTAssertNotNil(store.transactions[0].pendingSplitDraft)

        store.savePending(receipt("1.00", 9))
        store.deletePending(store.pendingReceipts[0])
        XCTAssertTrue(BudgetStore(folder: folder).pendingReceipts.isEmpty)
    }
}
