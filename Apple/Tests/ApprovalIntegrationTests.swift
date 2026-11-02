import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class ApprovalIntegrationTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func draft(reviewed: Bool, amount: String = "3.69") -> SplitDraft {
        let receipt = ReceiptRecord(imagePath: "", merchant: "Shop", purchaseDate: nil, subtotal: nil, tax: nil, total: Decimal(string: amount), rawText: "", items: [], confidence: 1, reviewed: reviewed)
        return SplitDraft(receipt: receipt, proposedSplits: [TransactionSplit(label: "Milk", category: "Groceries", amount: Decimal(string: amount)!)])
    }

    private func shopTransaction() -> BankTransaction {
        BankTransaction(date: Date(), merchant: "Shop", amount: Decimal(string: "-3.69")!, fingerprint: "tx")
    }

    func testApprovalCommitsAndClearsDraft() {
        let store = BudgetStore(folder: folder)
        let transaction = shopTransaction()
        store.transactions = [transaction]
        store.saveDraft(draft(reviewed: false), for: transaction)
        store.approve(draft(reviewed: true), for: transaction)
        XCTAssertEqual(store.transactions[0].splits.count, 1)
        XCTAssertNil(store.transactions[0].pendingSplitDraft)
        XCTAssertEqual(store.changes.count, 1)
    }

    func testUnreviewedDraftIsBlockedWithReason() {
        let store = BudgetStore(folder: folder)
        let transaction = shopTransaction()
        store.transactions = [transaction]
        guard case .failure(.notReviewed) = store.approve(draft(reviewed: false), for: transaction) else { return XCTFail("Expected notReviewed") }
        XCTAssertTrue(store.transactions[0].splits.isEmpty)
        XCTAssertTrue(store.status.contains("tick the box"))
    }

    func testUnbalancedDraftIsBlocked() {
        let store = BudgetStore(folder: folder)
        let transaction = shopTransaction()
        store.transactions = [transaction]
        guard case .failure(.unbalanced) = store.approve(draft(reviewed: true, amount: "3.00"), for: transaction) else { return XCTFail("Expected unbalanced") }
        XCTAssertTrue(store.transactions[0].splits.isEmpty)
    }

    func testApprovalHistorySurvivesRestart() {
        let transaction = shopTransaction()
        let first = BudgetStore(folder: folder)
        first.transactions = [transaction]
        first.approve(draft(reviewed: true), for: transaction)

        let reopened = BudgetStore(folder: folder)
        XCTAssertEqual(reopened.changes.count, 1)
        XCTAssertEqual(reopened.transactions.first?.splits.count, 1)
    }

    func testStoreUsesGivenFolderOnly() {
        let store = BudgetStore(folder: folder)
        store.add(BankTransaction(date: Date(), merchant: "Cash", amount: -5, fingerprint: "manual:1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transactions.json").path))
    }

    func testSubscriptionsPersist() {
        let store = SubscriptionStore(folder: folder)
        store.save(.blank())
        XCTAssertEqual(SubscriptionStore(folder: folder).contracts.count, 1)
    }
}
