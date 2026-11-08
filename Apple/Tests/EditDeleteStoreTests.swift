import BudgetCore
import XCTest
@testable import BudgetReceipts

/// Everything you can add can be taken away again, and survives a relaunch that way.
@MainActor
final class EditDeleteStoreTests: XCTestCase {
    private var folder: URL!
    private let calendar = Calendar.current

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func month(_ offset: Int) -> Date { calendar.date(byAdding: .month, value: offset, to: Date())! }

    func testRemovingALimitEndsItFromThatMonthOnly() {
        let store = BudgetStore(folder: folder)
        store.setBudget(category: "Groceries", limit: 400, month: month(-2))
        store.removeBudget(category: "Groceries", month: month(0))
        XCTAssertEqual(store.calculator.budget(for: "Groceries", in: store.budgets, month: month(-1))?.limit, 400)
        XCTAssertNil(store.calculator.budget(for: "Groceries", in: store.budgets, month: month(0)))
        XCTAssertNil(BudgetStore(folder: folder).calculator.budget(for: "Groceries", in: BudgetStore(folder: folder).budgets, month: month(1)))
        // Setting it again brings it back.
        store.setBudget(category: "Groceries", limit: 300, month: month(0))
        XCTAssertEqual(store.calculator.budget(for: "Groceries", in: store.budgets, month: month(0))?.limit, 300)
    }

    func testSettleUpCanBeUndone() {
        let store = BudgetStore(folder: folder)
        var couple = store.couple
        couple.partnerName = "Sam"
        store.updateCouple(couple)
        store.transactions = [BankTransaction(date: Date(), merchant: "Tesco", amount: -40, category: "Groceries", fingerprint: "t1", owner: .shared)]
        store.settleUp()
        XCTAssertEqual(store.settlements.count, 1)
        store.deleteSettlement(store.settlements[0])
        XCTAssertTrue(BudgetStore(folder: folder).settlements.isEmpty)
    }

    func testSubscriptionsAndContractsAreDeleted() {
        let subscriptions = SubscriptionStore(folder: folder)
        let netflix = SubscriptionContract.blank(.subscription)
        var phone = SubscriptionContract.blank(.contract)
        phone.vendor = "Vodafone"
        subscriptions.save(netflix)
        subscriptions.save(phone)
        XCTAssertEqual(SubscriptionStore(folder: folder).contracts.map(\.resolvedKind), [.subscription, .contract])
        subscriptions.delete(phone)
        XCTAssertEqual(SubscriptionStore(folder: folder).contracts.map(\.id), [netflix.id])
    }
}
