import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class CoupleStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func groceries(_ amount: String, owner: MoneyOwner? = nil) -> BankTransaction {
        BankTransaction(date: Date(), merchant: "Tesco", amount: Decimal(string: amount)!, category: "Groceries", fingerprint: UUID().uuidString, owner: owner)
    }

    func testSinglePersonSeesEverythingWhateverTheSwitch() {
        let store = BudgetStore(folder: folder)
        store.transactions = [groceries("-40.00", owner: .shared)]
        store.householdView = .me
        XCTAssertFalse(store.hasPartner)
        XCTAssertEqual(store.spending, Decimal(string: "40.00"))
    }

    func testMeViewCountsMyHalfOfSharedSpending() {
        let store = BudgetStore(folder: folder)
        store.updateCouple(CoupleSettings(partnerName: "Sam"))
        store.transactions = [groceries("-40.00", owner: .shared), groceries("-10.00", owner: .partner)]
        store.householdView = .me
        XCTAssertEqual(store.spending, Decimal(string: "20.00"))
        store.householdView = .together
        XCTAssertEqual(store.spending, Decimal(string: "50.00"))
    }

    func testRulesOwnerBalanceAndSettlementsPersist() {
        let store = BudgetStore(folder: folder)
        store.updateCouple(CoupleSettings(partnerName: "Sam", rules: [OwnerRule(match: .category("Groceries"), owner: .shared)]))
        store.transactions = [groceries("-50.00")]
        XCTAssertEqual(store.coupleBalance.debtor, .partner)
        XCTAssertEqual(store.coupleBalance.amountOwed, Decimal(string: "25.00"))
        store.setOwner(.mine, for: store.transactions[0])
        XCTAssertNil(store.coupleBalance.debtor)
        store.setOwner(nil, for: store.transactions[0])
        store.settleUp()
        XCTAssertNil(store.coupleBalance.debtor)

        let reloaded = BudgetStore(folder: folder)
        XCTAssertEqual(reloaded.couple.partnerName, "Sam")
        XCTAssertEqual(reloaded.settlements.count, 1)
        XCTAssertNil(reloaded.transactions[0].owner)
        XCTAssertNil(reloaded.coupleBalance.debtor)
    }

    func testRemovingThePartnerResetsTheSwitch() {
        let store = BudgetStore(folder: folder)
        store.updateCouple(CoupleSettings(partnerName: "Sam"))
        store.householdView = .partner
        store.updateCouple(CoupleSettings())
        XCTAssertEqual(store.householdView, .together)
    }
}

@MainActor
final class ManualEntryAndResetTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testManualTransactionIsAddedAndDeleted() {
        let store = BudgetStore(folder: folder)
        let coffee = BankTransaction(date: Date(), merchant: "Coffee", amount: Decimal(string: "-3.20")!, category: "Eating out", fingerprint: "manual:1")
        store.add(coffee)
        XCTAssertTrue(store.transactions[0].isManual)
        store.delete(coffee)
        XCTAssertTrue(BudgetStore(folder: folder).transactions.isEmpty)
    }

    func testResetRemovesEverythingAndTellsSync() {
        let store = BudgetStore(folder: folder)
        var changed = 0
        store.didPersist = { changed += 1 }
        store.add(BankTransaction(date: Date(), merchant: "Coffee", amount: -3, fingerprint: "manual:1"))
        store.addAccount(name: "Current")
        store.setBudget(category: "Groceries", limit: 200)
        store.savePending(ReceiptDraftEditor(merchant: "Shop"))
        store.resetAllData()
        let reopened = BudgetStore(folder: folder)
        XCTAssertTrue(reopened.transactions.isEmpty && reopened.accounts.isEmpty && reopened.budgets.isEmpty && reopened.pendingReceipts.isEmpty)
        XCTAssertGreaterThan(changed, 4, "iCloud sync hears about the reset")
        XCTAssertTrue(store.syncRecords().allSatisfy { $0.collection == "couple" }, "Only the default couple settings are left to sync")
    }
}
