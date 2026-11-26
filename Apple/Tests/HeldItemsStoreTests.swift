import BudgetCore
import XCTest
@testable import BudgetReceipts

/// Synced items from a newer version are kept, never sent back as deletions.
@MainActor
final class HeldItemsStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let newer = SyncRecord(collection: "future.thing", id: "1", payload: Data("{}".utf8))

    /// A store that understands the newer kind, standing in for a later version.
    private final class FutureStore: SyncSource {
        let collections: Set<String> = ["future.thing"]
        var records: [SyncRecord] = []
        var savesWork = true
        var unreadableFiles: [String] { [] }
        func syncRecords() -> [SyncRecord] { records }
        func applySync(saves: [SyncRecord], deletes: Set<String>) -> Bool {
            if savesWork { records += saves }
            return savesWork
        }
    }

    func testEveryKindTheStoresSendIsListed() {
        let budget = SampleData.budgetStore()
        let subscriptions = SampleData.subscriptionStore()
        for source in [budget, subscriptions] as [SyncSource] {
            let sent = Set(source.syncRecords().map(\.collection))
            XCTAssertFalse(sent.isEmpty)
            XCTAssertEqual(sent.subtracting(source.collections), [])
        }
    }

    func testAnUnknownItemIsKeptAcrossLaunchesAndNotSentAsDeleted() {
        let store = BudgetStore(folder: folder)
        let held = HeldItemsStore(folder: folder, known: store.collections)
        let coffee = SyncRecord.records([BankTransaction(date: Date(), merchant: "COSTA", amount: -3, fingerprint: "c")],
                                        collection: "transactions", id: \.fingerprint)[0]
        XCTAssertTrue(store.applySync(saves: [coffee, newer], deletes: []))
        XCTAssertTrue(held.applySync(saves: [coffee, newer], deletes: []))
        XCTAssertEqual(held.syncRecords(), [newer])
        XCTAssertEqual(HeldItemsStore(folder: folder, known: store.collections).syncRecords(), [newer])
        var state = SyncState()
        state.recordSaved(coffee)
        state.recordSaved(newer)
        let current = store.syncRecords() + held.syncRecords()
        XCTAssertFalse(state.changes(to: current).deletes.map(\.key).contains(newer.key))
        XCTAssertTrue(held.applySync(saves: [], deletes: [newer.key]))
        XCTAssertTrue(held.syncRecords().isEmpty)
    }

    func testAStoreThatUnderstandsItTakesItOverOnlyOnceSaved() {
        let held = HeldItemsStore(folder: folder, known: [])
        held.applySync(saves: [newer], deletes: [])
        let future = FutureStore()
        future.savesWork = false
        held.release(to: [future, held])
        XCTAssertEqual(held.syncRecords(), [newer])
        future.savesWork = true
        held.release(to: [future, held])
        XCTAssertEqual(future.records, [newer])
        XCTAssertTrue(held.syncRecords().isEmpty)
        XCTAssertTrue(HeldItemsStore(folder: folder, known: []).syncRecords().isEmpty)
    }

    func testErasingRemovesHeldItemsAndBackupsCarryThem() throws {
        let store = BudgetStore(folder: folder)
        let held = HeldItemsStore(folder: folder, known: store.collections)
        held.applySync(saves: [newer], deletes: [])
        let backup = try EncryptedBackup.make(folder: folder, password: "long enough", device: "", appVersion: "")
        held.resetAllData()
        XCTAssertTrue(held.syncRecords().isEmpty)
        let subscriptions = SubscriptionStore(folder: folder)
        try store.restore(EncryptedBackup.open(backup, password: "long enough"), subscriptions: subscriptions, held: held)
        XCTAssertEqual(held.syncRecords(), [newer])
    }

    func testADamagedFileIsSetAsideSoSyncRebuildsIt() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("held-items.json"))
        let held = HeldItemsStore(folder: folder, known: [])
        XCTAssertEqual(held.unreadableFiles, ["held-items.json"])
        XCTAssertTrue(held.syncRecords().isEmpty)
    }
}
