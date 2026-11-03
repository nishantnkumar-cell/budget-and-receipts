import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class CategoriesStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        FinanceCategories.catalog = .default
    }

    private func payment(_ category: String, subcategory: String? = nil) -> BankTransaction {
        var transaction = BankTransaction(date: Date(), merchant: "SHOP", amount: Decimal(string: "-9.99")!, category: category, fingerprint: UUID().uuidString)
        transaction.subcategory = subcategory
        return transaction
    }

    func testRenamingMovesPaymentsBudgetsAndRulesAndIsSaved() {
        let store = BudgetStore(folder: folder)
        store.add(payment("Groceries", subcategory: "Supermarket"))
        store.setBudget(category: "Groceries", limit: Decimal(string: "300")!)
        XCTAssertNil(store.editCategories { try $0.rename("Groceries", to: "Food") })

        XCTAssertEqual(store.transactions.first?.category, "Food")
        XCTAssertEqual(store.transactions.first?.subcategory, "Supermarket")
        XCTAssertTrue(store.budgets.allSatisfy { $0.category == "Food" })
        XCTAssertFalse(store.rules.contains { $0.category == "Groceries" })
        XCTAssertTrue(FinanceCategories.all.contains("Food"))

        let reopened = BudgetStore(folder: folder)
        XCTAssertTrue(reopened.catalog.all.contains("Food"))
        // A payment added later in the old name (an older device, a starter rule) follows.
        reopened.add(payment("Groceries"))
        XCTAssertFalse(reopened.transactions.contains { $0.category == "Groceries" })
    }

    func testDeletingMovesPaymentsToTheChosenCategory() {
        let store = BudgetStore(folder: folder)
        store.add(payment("Education", subcategory: "Courses"))
        XCTAssertNil(store.editCategories { try $0.delete("Education", movingTo: "Family") })
        XCTAssertEqual(store.transactions.first?.category, "Family")
        XCTAssertNil(store.transactions.first?.subcategory)
        XCTAssertFalse(store.catalog.all.contains("Education"))
    }

    func testLockedCategoryRenameIsRefusedWithAMessage() {
        let store = BudgetStore(folder: folder)
        XCTAssertNotNil(store.editCategories { try $0.rename("Income", to: "Money in") })
        XCTAssertTrue(store.categories.isEmpty)
    }

    func testCategoriesTravelThroughSync() {
        let store = BudgetStore(folder: folder)
        XCTAssertNil(store.editCategories { _ = try $0.add(name: "Pets", symbol: "pawprint", color: .amber) })
        let records = store.syncRecords().filter { $0.collection == "categories" }
        XCTAssertEqual(records.count, 1)

        let other = BudgetStore(folder: folder.appendingPathComponent("other", isDirectory: true))
        other.applySync(saves: records, deletes: [])
        XCTAssertTrue(other.catalog.all.contains("Pets"))
    }
}
