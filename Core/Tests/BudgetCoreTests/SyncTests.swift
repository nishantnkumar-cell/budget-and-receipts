import XCTest
@testable import BudgetCore

final class SyncTests: XCTestCase {
    private func tx(_ id: String, _ amount: String, isPrivate: Bool? = nil) -> BankTransaction {
        var transaction = BankTransaction(date: Date(timeIntervalSince1970: 1_790_000_000), merchant: "M", amount: money(amount), fingerprint: id)
        transaction.isPrivate = isPrivate
        return transaction
    }

    private func records(_ items: [BankTransaction]) -> [SyncRecord] {
        SyncRecord.records(items, collection: "transactions", id: \.fingerprint, isPrivate: { $0.isPrivate == true })
    }

    func testEncodingIsStableSoUnchangedItemsAreNotResent() {
        let first = records([tx("a", "-1.00")])
        var state = SyncState()
        first.forEach { state.recordSaved($0) }
        XCTAssertTrue(state.changes(to: records([tx("a", "-1.00")])).isEmpty)
    }

    func testNewChangedAndDeletedItems() {
        var state = SyncState()
        records([tx("a", "-1.00"), tx("b", "-2.00")]).forEach { state.recordSaved($0) }
        let changes = state.changes(to: records([tx("a", "-1.50"), tx("c", "-3.00")]))
        XCTAssertEqual(changes.saves.map(\.id).sorted(), ["a", "c"])
        XCTAssertEqual(changes.deletes.map(\.key), ["transactions|b"])
    }

    func testMarkingPrivateMovesTheItemBetweenZones() {
        var state = SyncState()
        records([tx("a", "-1.00")]).forEach { state.recordSaved($0) }
        let changes = state.changes(to: records([tx("a", "-1.00", isPrivate: true)]))
        XCTAssertEqual(changes.deletes, [.init(key: "transactions|a", isPrivate: false)], "Removed from the shared zone")
        XCTAssertEqual(changes.saves.first?.isPrivate, true, "Saved in the private zone")
    }

    func testEverythingIsSharedUnlessMarked() {
        XCTAssertEqual(records([tx("a", "-1.00")]).first?.isPrivate, false)
    }

    func testArrivalsReplaceAddAndDelete() {
        let local = [tx("a", "-1.00"), tx("b", "-2.00")]
        let incoming = records([tx("a", "-9.00"), tx("c", "-3.00")])
        let merged = SyncMerge.apply(saves: incoming, deletes: ["transactions|b"], to: local, collection: "transactions", id: \.fingerprint)
        XCTAssertEqual(merged.map(\.fingerprint), ["a", "c"])
        XCTAssertEqual(merged.first?.amount, money("-9.00"))
    }

    func testRecordsFromOtherCollectionsAndBadDataAreIgnored() {
        let alien = SyncRecord(collection: "budgets", id: "a", payload: Data("{}".utf8))
        let broken = SyncRecord(collection: "transactions", id: "z", payload: Data("not json".utf8))
        let merged = SyncMerge.apply(saves: [alien, broken], deletes: [], to: [tx("a", "-1.00")], collection: "transactions", id: \.fingerprint)
        XCTAssertEqual(merged.map(\.fingerprint), ["a"])
    }

    func testStateSurvivesSaving() throws {
        var state = SyncState()
        records([tx("a", "-1.00", isPrivate: true)]).forEach { state.recordSaved($0) }
        XCTAssertEqual(try JSONDecoder().decode(SyncState.self, from: JSONEncoder().encode(state)), state)
    }
}
