import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class RulesStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func payment(_ merchant: String, _ amount: Decimal, monthsAgo: Int = 0, category: String = "Uncategorised") -> BankTransaction {
        let date = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date())!
        return BankTransaction(date: date, merchant: merchant, amount: amount, category: category, fingerprint: UUID().uuidString)
    }

    func testNewHouseholdStartsWithStarterRulesAndYourRulesComeFirst() {
        let store = BudgetStore(folder: folder)
        XCTAssertEqual(store.rules.count, RulesEngine.starterRules.count)
        let mine = CategoryRule(name: "Corner shop", conditions: [.init(.description, .contains, "RAJ STORES")], category: "Groceries", subcategory: "Convenience store")
        store.saveRule(mine)
        XCTAssertEqual(store.rules.first?.id, mine.id)
        // Saved and read back, in the same order.
        XCTAssertEqual(BudgetStore(folder: folder).rules.first?.id, mine.id)
    }

    func testDeletingAStarterRuleTurnsItOffAndItStaysOff() {
        let store = BudgetStore(folder: folder)
        let starter = store.rules.first { $0.name == "Supermarkets" }!
        store.deleteRule(starter)
        let reopened = BudgetStore(folder: folder)
        XCTAssertEqual(reopened.rules.count, RulesEngine.starterRules.count)
        XCTAssertEqual(reopened.rules.first { $0.id == starter.id }?.isEnabled, false)
    }

    func testRulesCategoriseAndFillInSubcategories() {
        let store = BudgetStore(folder: folder)
        store.add(payment("SAINSBURYS S/MKTS", -20))
        store.add(payment("WAITROSE 612", -30, category: "Groceries"))
        XCTAssertEqual(store.applyRules(), 2)
        XCTAssertTrue(store.transactions.allSatisfy { $0.category == "Groceries" && $0.subcategory == "Supermarket" })
        let rule = CategoryRule(name: "Waitrose is a treat", conditions: [.init(.description, .contains, "WAITROSE")], category: "Eating out")
        XCTAssertEqual(store.matches(for: rule).count, 1)
        XCTAssertEqual(store.apply(rule), 1)
        XCTAssertEqual(store.transactions.first { $0.merchant.hasPrefix("WAITROSE") }?.category, "Eating out")
    }

    func testAMonthWithNoPaymentsIsEmptyAndTheAppOpensOnTheLatestMonth() {
        let store = BudgetStore(folder: folder)
        store.add(payment("TESCO", -10, monthsAgo: 2))
        store.selectedMonth = Date()
        XCTAssertTrue(store.selectedMonthIsEmpty)
        store.showLatestMonthWithPayments()
        XCTAssertFalse(store.selectedMonthIsEmpty)
        XCTAssertFalse(BudgetStore(folder: folder).selectedMonthIsEmpty, "Opens on a month with payments")
        XCTAssertFalse(BudgetStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).selectedMonthIsEmpty, "No data at all isn't an empty month")
    }
}
