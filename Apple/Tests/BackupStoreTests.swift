import BudgetCore
import XCTest
@testable import BudgetReceipts

/// Encrypted backups, and returns and warranties on receipts.
@MainActor
final class BackupStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testBackupRoundTripReplacesEverything() throws {
        let store = BudgetStore(folder: folder)
        let subscriptions = SubscriptionStore(folder: folder)
        store.add(BankTransaction(date: Date(), merchant: "Tesco", amount: Decimal(string: "-12.34")!, category: "Groceries", fingerprint: "keep"))
        store.saveCover(ProductCover(item: "Kettle", shop: "Argos", purchased: Date(), returnBy: Date().addingTimeInterval(86_400 * 10), receiptImage: "photo.jpg"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Receipts"), withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: folder.appendingPathComponent("Receipts/photo.jpg"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("sync-state.json"))
        let backup = try EncryptedBackup.make(folder: folder, password: "correct horse", device: "Test", appVersion: "1.0")
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("Tesco"), "The file must be encrypted")

        XCTAssertThrowsError(try EncryptedBackup.open(backup, password: "wrong password")) { error in
            XCTAssertEqual(error as? EncryptedBackup.Failure, .wrongPassword)
        }
        let contents = try EncryptedBackup.open(backup, password: "correct horse")
        XCTAssertEqual(contents.transactionCount, 1)
        XCTAssertEqual(contents.photoCount, 1)
        XCTAssertNil(contents.files["sync-state.json"], "This device's iCloud state isn't backed up")

        // Later changes are replaced by the backup.
        store.add(BankTransaction(date: Date(), merchant: "Added later", amount: -5, fingerprint: "later"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Receipts/photo.jpg"))
        try store.restore(contents, subscriptions: subscriptions)
        XCTAssertEqual(store.transactions.map(\.fingerprint), ["keep"])
        XCTAssertEqual(store.transactions.first?.amount, Decimal(string: "-12.34")!)
        XCTAssertEqual(store.covers.first?.item, "Kettle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Receipts/photo.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sync-state.json").path), "iCloud state is left alone")
        XCTAssertEqual(BudgetStore(folder: folder).transactions.count, 1)
    }

    func testShortPasswordAndDamagedFilesAreRefused() throws {
        XCTAssertThrowsError(try EncryptedBackup.make(folder: folder, password: "short", device: "", appVersion: ""))
        XCTAssertThrowsError(try EncryptedBackup.open(Data("not a backup".utf8), password: "whatever1"))
        var backup = try EncryptedBackup.make(folder: folder, password: "long enough", device: "", appVersion: "")
        backup[backup.count - 1] ^= 0xFF
        XCTAssertThrowsError(try EncryptedBackup.open(backup, password: "long enough"))
    }

    func testUnsafePathsAreRejected() {
        XCTAssertTrue(EncryptedBackup.isSafe("transactions.json"))
        XCTAssertTrue(EncryptedBackup.isSafe("Receipts/abc.jpg"))
        XCTAssertFalse(EncryptedBackup.isSafe("../evil.json"))
        XCTAssertFalse(EncryptedBackup.isSafe("Receipts/../../x"))
        XCTAssertFalse(EncryptedBackup.isSafe("/etc/passwd"))
        XCTAssertFalse(EncryptedBackup.isSafe("sync-engine.json"))
    }

    func testCoverKeepsItsReceiptPhotoSyncingAndCanBeDeleted() throws {
        let store = BudgetStore(folder: folder)
        let images = ReceiptImageStore(dataFolder: folder)
        let name = try images.save(Data("jpeg".utf8))
        let cover = ProductCover(item: "TV", shop: "Currys", purchased: Date(), warrantyEnds: Date().addingTimeInterval(86_400 * 400), receiptImage: name)
        store.saveCover(cover)
        let records = store.syncRecords()
        XCTAssertNotNil(records.first { $0.collection == "covers" })
        XCTAssertNotNil(records.first { $0.collection == "images" && $0.id == name })
        store.deleteCover(cover)
        XCTAssertTrue(BudgetStore(folder: folder).covers.isEmpty)
    }
}
