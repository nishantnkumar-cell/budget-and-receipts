import XCTest
@testable import BudgetCore

final class HeldRecordsTests: XCTestCase {
    private let known: Set<String> = ["transactions"]
    private let old = SyncRecord(collection: "transactions", id: "a", payload: Data("1".utf8))
    private let newer = SyncRecord(collection: "tax.property", id: "p|1", payload: Data("2".utf8), isPrivate: true)

    func testKeepsOnlyUnknownKindsAndDropsDeletedOnes() {
        var held = HeldRecords()
        XCTAssertTrue(held.apply(saves: [old, newer], deletes: [], known: known))
        XCTAssertEqual(held.records, [newer])
        XCTAssertFalse(held.apply(saves: [newer], deletes: [old.key], known: known))
        XCTAssertTrue(held.apply(saves: [], deletes: [newer.key], known: known))
        XCTAssertTrue(held.isEmpty)
    }

    /// The flaw this fixes: an arrival noted as synced, but not held, is sent back as a deletion.
    func testAHeldItemIsNeverSentAsDeleted() {
        var state = SyncState()
        state.recordSaved(old)
        state.recordSaved(newer)
        XCTAssertEqual(state.changes(to: [old]).deletes.map(\.key), [newer.key])
        var held = HeldRecords()
        held.apply(saves: [old, newer], deletes: [], known: known)
        XCTAssertTrue(state.changes(to: [old] + held.records).isEmpty)
    }

    func testForgetsLostUnknownItemsWithoutTouchingKnownDeletions() {
        var state = SyncState()
        state.recordSaved(old)
        state.recordSaved(newer)
        XCTAssertEqual(state.forgetUnknown(known: known, keeping: []), 1)
        // The known item really was deleted here, so that deletion still goes out.
        XCTAssertEqual(state.changes(to: []).deletes.map(\.key), [old.key])
    }

    func testForgetKeepsAHeldItemSoErasingStillDeletesIt() {
        var state = SyncState()
        state.recordSaved(newer)
        XCTAssertEqual(state.forgetUnknown(known: known, keeping: [newer.key]), 0)
        XCTAssertEqual(state.changes(to: []).deletes.map(\.key), [newer.key])
    }

    func testANewerCopyOfANowKnownItemDropsTheHeldOne() {
        var held = HeldRecords([newer])
        XCTAssertTrue(held.apply(saves: [newer], deletes: [], known: [newer.collection]))
        XCTAssertTrue(held.isEmpty)
    }

    func testRestoringABackupNeverLosesAHeldItem() {
        let other = SyncRecord(collection: "tax.rule", id: "r", payload: Data("3".utf8))
        var changed = newer
        changed.payload = Data("old".utf8)
        let held = HeldRecords([newer, other])
        XCTAssertEqual(held.restored(from: HeldRecords()).records, held.records)
        XCTAssertEqual(held.restored(from: HeldRecords([changed])).records, HeldRecords([changed, other]).records)
    }

    func testChangingSidesInAHouseholdKeepsOnlyPrivateItems() {
        var held = HeldRecords([newer, SyncRecord(collection: "tax.rule", id: "r", payload: Data())])
        held.removeShared()
        XCTAssertEqual(held.records, [newer])
    }

    func testADeletionFromTheZoneAnItemLeftIsIgnored() {
        var state = SyncState()
        state.recordSaved(newer)
        XCTAssertTrue(state.isLeftover(newer.key, deletedFromPrivate: false))
        XCTAssertFalse(state.isLeftover(newer.key, deletedFromPrivate: true))
        XCTAssertFalse(state.isLeftover("transactions|unseen", deletedFromPrivate: false))
    }

    func testSurvivesBeingSaved() throws {
        var record = newer
        record.fileName = "x.pdf"
        let data = try JSONEncoder().encode([record])
        XCTAssertEqual(try JSONDecoder().decode([SyncRecord].self, from: data), [record])
    }
}
