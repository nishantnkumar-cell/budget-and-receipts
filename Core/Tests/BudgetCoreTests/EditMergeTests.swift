import XCTest
@testable import BudgetCore

final class EditMergeTests: XCTestCase {
    private var payment: BankTransaction {
        var payment = BankTransaction(date: Date(timeIntervalSince1970: 1_750_000_000.125), merchant: "Shop", description: "d",
                                      amount: money("-12.99"), fingerprint: "f")
        payment.tags = ["one"]
        return payment
    }

    private let together = [["amount", "splits", "pendingSplitDraft"]]

    func testNothingChangedLeavesWhatIsSavedExactly() {
        var current = payment
        current.isPrivate = true
        current.merchant = "Renamed elsewhere"
        current.foreign = ForeignAmount(amount: money("15.01"), currency: "EUR")
        XCTAssertEqual(EditMerge.apply(payment, editedFrom: payment, onto: current), current)
    }

    func testOnlyTheEditedFieldsAreWrittenSoAPaymentMadePrivateStaysPrivate() {
        var current = payment
        current.isPrivate = true
        current.tripID = UUID()
        var draft = payment
        draft.category = "Groceries"
        draft.amount = money("-13.01")
        let result = EditMerge.apply(draft, editedFrom: payment, onto: current, together: together)
        XCTAssertEqual(result.isPrivate, true)
        XCTAssertEqual(result.tripID, current.tripID)
        XCTAssertEqual(result.category, "Groceries")
        XCTAssertEqual(result.amount, money("-13.01"))
        XCTAssertEqual(result.date, payment.date)
    }

    func testAFieldClearedInTheEditIsCleared() {
        var current = payment
        current.merchant = "Renamed"
        var draft = payment
        draft.tags = nil
        let result = EditMerge.apply(draft, editedFrom: payment, onto: current)
        XCTAssertNil(result.tags)
        XCTAssertEqual(result.merchant, "Renamed")
    }

    func testAnAmountAndItsSplitStayTogether() {
        var current = payment
        current.splits = [TransactionSplit(label: "a", category: "Groceries", amount: money("12.99"))]
        var draft = payment
        draft.amount = money("-20")
        let result = EditMerge.apply(draft, editedFrom: payment, onto: current, together: together)
        XCTAssertEqual(result.amount, money("-20"))
        XCTAssertEqual(result.splits, [])
        // An edit that touches neither keeps the split made elsewhere.
        var renamed = payment
        renamed.merchant = "New name"
        XCTAssertEqual(EditMerge.apply(renamed, editedFrom: payment, onto: current, together: together).splits, current.splits)
    }

    func testItemsAddedOnBothSidesAreBothKeptAndRemovalsHold() {
        let first = SavingsGoal.Contribution(date: Date(timeIntervalSince1970: 1_000), amount: 1)
        let second = SavingsGoal.Contribution(date: Date(timeIntervalSince1970: 2_000), amount: 2)
        let original = SavingsGoal(name: "Goal", target: 100, contributions: [first, second], createdAt: Date(timeIntervalSince1970: 0))
        var current = original
        let theirs = SavingsGoal.Contribution(date: Date(timeIntervalSince1970: 3_000), amount: 3)
        current.contributions.append(theirs)
        var draft = original
        let mine = SavingsGoal.Contribution(date: Date(timeIntervalSince1970: 4_000), amount: 4)
        draft.contributions = [second, mine]
        let result = EditMerge.apply(draft, editedFrom: original, onto: current)
        XCTAssertEqual(result.contributions, [second, theirs, mine])
        // One removed elsewhere, untouched here, stays removed.
        var removed = original
        removed.contributions = [second]
        var renamed = original
        renamed.name = "Renamed"
        XCTAssertEqual(EditMerge.apply(renamed, editedFrom: original, onto: removed).contributions, [second])
    }
}

final class UnreadableSyncTests: XCTestCase {
    private func record(_ key: String, _ text: String) -> SyncRecord {
        let parts = key.split(separator: "|")
        return SyncRecord(collection: String(parts[0]), id: String(parts[1]), payload: Data(text.utf8))
    }

    func testNothingIsSentOverAnItemThatCantBeRead() {
        var state = SyncState()
        let old = record("transactions|a", "old"), gone = record("transactions|b", "x"), photo = record("images|p", "")
        for item in [old, gone, photo] { state.recordSaved(item) }
        state.recordUnreadable(old.key)
        state.recordUnreadable("transactions|new")
        // The older copy changed here, the unknown new one is absent, and the photo it might use too.
        let changes = state.changes(to: [record("transactions|a", "edited"), gone])
        XCTAssertEqual(changes.saves, [])
        XCTAssertEqual(changes.deletes, [])
        // An ordinary deletion still goes.
        XCTAssertEqual(state.changes(to: [old]).deletes.map(\.key), ["transactions|b"])
        // Once a readable version arrives, or it's deleted, things go on as before.
        state.recordSaved(old)
        state.recordDeleted("transactions|new")
        XCTAssertEqual(state.changes(to: [record("transactions|a", "edited"), gone]).saves.map(\.key), ["transactions|a"])
        XCTAssertEqual(state.changes(to: [old, gone]).deletes.map(\.key), ["images|p"])
    }

    func testAnOlderSavedStateStillLoads() throws {
        let old = try JSONDecoder().decode(SyncState.self, from: Data(#"{"entries":{}}"#.utf8))
        XCTAssertNil(old.unreadable)
    }
}
