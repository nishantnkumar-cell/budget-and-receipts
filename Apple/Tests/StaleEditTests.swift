import BudgetCore
import XCTest
@testable import BudgetReceipts

/// A screen left open while another device changes the same item.
@MainActor
final class StaleEditTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSavingAnOpenPaymentDoesntShareOneMadePrivateMeanwhile() {
        let store = BudgetStore(folder: folder)
        let opened = BankTransaction(date: Date(), merchant: "Shop", amount: -10, fingerprint: "p")
        store.add(opened)
        var elsewhere = store.transactions[0]
        elsewhere.isPrivate = true
        store.update(elsewhere)
        var draft = opened
        draft.category = "Groceries"
        let saved = store.update(draft, editedFrom: opened)
        XCTAssertEqual(saved?.isPrivate, true)
        XCTAssertEqual(store.transactions[0].isPrivate, true)
        XCTAssertEqual(store.transactions[0].category, "Groceries")
        store.delete(store.transactions[0])
        XCTAssertNil(store.update(draft, editedFrom: opened))
        XCTAssertTrue(store.transactions.isEmpty)
    }

    func testAccountsGoalsAndContractsKeepAPrivacyChangeToo() {
        let store = BudgetStore(folder: folder)
        let account = store.addAccount(name: "Joint")
        var hidden = account
        hidden.isPrivate = true
        store.updateAccount(hidden)
        var renamed = account
        renamed.name = "Bills"
        store.updateAccount(renamed, editedFrom: account)
        XCTAssertEqual(store.accounts.first?.isPrivate, true)
        XCTAssertEqual(store.accounts.first?.name, "Bills")

        let goal = SavingsGoal(name: "Holiday", target: 500)
        store.saveGoal(goal)
        var private_ = goal
        private_.isPrivate = true
        store.saveGoal(private_)
        var bigger = goal
        bigger.target = 600
        store.saveGoal(bigger, editedFrom: goal)
        XCTAssertEqual(store.goals.first?.isPrivate, true)
        XCTAssertEqual(store.goals.first?.target, 600)
        store.deleteGoal(store.goals[0])
        store.saveGoal(bigger, editedFrom: goal)
        XCTAssertTrue(store.goals.isEmpty)

        let subscriptions = SubscriptionStore(folder: folder)
        let contract = SubscriptionContract(vendor: "Sample", category: .streaming, startDate: Date(), billingPeriod: .monthly,
                                            nextPaymentDueDate: Date(), expectedAmount: 5, currency: "GBP")
        subscriptions.save(contract)
        var shown = contract
        shown.isPrivate = true
        subscriptions.save(shown)
        var dearer = contract
        dearer.expectedAmount = 7
        subscriptions.save(dearer, editedFrom: contract)
        XCTAssertEqual(subscriptions.contracts.first?.isPrivate, true)
        XCTAssertEqual(subscriptions.contracts.first?.expectedAmount, 7)
    }

    func testEachStoreSaysWhatItCantRead() {
        let store = BudgetStore(folder: folder)
        let subscriptions = SubscriptionStore(folder: folder)
        store.add(BankTransaction(date: Date(), merchant: "Shop", amount: -10, fingerprint: "p"))
        let good = store.syncRecords().first { $0.collection == "transactions" }!
        XCTAssertTrue(store.canRead(good))
        let newer = SyncRecord(collection: "transactions", id: "q", payload: Data(#"{"shape":"new"}"#.utf8))
        let contract = SyncRecord(collection: "contracts", id: "c", payload: Data("{}".utf8))
        XCTAssertFalse(store.canRead(newer))
        XCTAssertFalse(subscriptions.canRead(contract))
        let sources: [SyncSource] = [store, subscriptions]
        XCTAssertEqual(sources.unreadableKeys([good, newer, contract]), [newer.key, contract.key])
    }
}
