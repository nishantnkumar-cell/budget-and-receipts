import BudgetCore
import ImageIO
import XCTest
@testable import BudgetReceipts

@MainActor
final class HouseholdStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func record(_ transaction: BankTransaction, byPartner: Bool = false) -> SyncRecord {
        var record = SyncRecord.records([transaction], collection: "transactions", id: \.fingerprint)[0]
        record.byPartner = byPartner
        return record
    }

    func testPartnerDeletionCanBeRestored() {
        let store = BudgetStore(folder: folder)
        store.householdRole = .owner
        let coffee = BankTransaction(date: Date(), merchant: "COSTA", amount: -3, fingerprint: "c")
        store.add(coffee)
        store.applySync(saves: [], deletes: [SyncRecord.key("transactions", "c")])
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertEqual(store.recentChanges.first?.kind, .deleted)
        store.restore(store.recentChanges[0])
        XCTAssertEqual(store.transactions.map(\.merchant), ["COSTA"])
        XCTAssertTrue(store.recentChanges.isEmpty)
    }

    func testPartnerCantChangeCoupleSettingsOrOwnersAccounts() {
        let store = BudgetStore(folder: folder)
        store.householdRole = .owner
        store.updateCouple(CoupleSettings(partnerName: "Shweta"))
        let mine = store.addAccount(name: "My current")
        var hijacked = mine
        hijacked.name = "Changed by partner"
        var accountRecord = SyncRecord.records([hijacked], collection: "accounts", id: \.id.uuidString)[0]
        accountRecord.byPartner = true
        var coupleRecord = SyncRecord.records([CoupleSettings(partnerName: "Someone else")], collection: "couple", id: { _ in "settings" })[0]
        coupleRecord.byPartner = true
        store.applySync(saves: [accountRecord, coupleRecord], deletes: [])
        XCTAssertEqual(store.accounts.first?.name, "My current")
        XCTAssertEqual(store.couple.partnerName, "Shweta")
        XCTAssertEqual(store.rejectedKeys([]), [accountRecord.key, coupleRecord.key])
    }

    func testPartnersPhoneSeesItFromHerSide() {
        let store = BudgetStore(folder: folder)
        store.householdRole = .member
        // Stored from the owner's side: the owner paid, for the partner's shampoo.
        let shampoo = BankTransaction(date: Date(), merchant: "BOOTS", amount: -6, fingerprint: "b", owner: .partner, paidBy: .me)
        store.applySync(saves: [record(shampoo)], deletes: [])
        XCTAssertEqual(store.transactions.first?.owner, .mine, "Hers, on her phone")
        XCTAssertEqual(store.transactions.first?.paidBy, .partner)
        // Going back up it is turned to the owner's side again.
        let outgoing = store.syncRecords().first { $0.collection == "transactions" }!
        XCTAssertEqual(try SyncRecord.decoder().decode(BankTransaction.self, from: outgoing.payload).owner, .partner)
    }

    func testUnreadableFileIsKeptAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("transactions.json"))
        let store = BudgetStore(folder: folder)
        XCTAssertEqual(store.unreadableFiles, ["transactions.json"])
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("transactions.json.unreadable-") }
        XCTAssertEqual(kept.count, 1, "The damaged file is kept for recovery")
    }

    func testDataFolderIsLeftOutOfDeviceBackup() throws {
        _ = BudgetStore(folder: folder)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}

final class ReceiptPhotoPrivacyTests: XCTestCase {
    func testLocationAndCameraDetailsAreRemoved() throws {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLongitude: 0.12]
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let clean = try XCTUnwrap(ReceiptImageStore.withoutMetadata(output as Data))
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(clean as CFData, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNil(properties?[kCGImagePropertyGPSDictionary])
        XCTAssertNil(ReceiptImageStore.withoutMetadata(Data("%PDF-1.4".utf8)), "Not an image: kept as it is")
    }
}

@MainActor
final class NetWorthStoreTests: XCTestCase {
    func testAccountsBalancesNotesAndSync() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BudgetStore(folder: folder)
        let pension = WealthAccount(name: "Workplace pension", kind: .pension)
        let card = WealthAccount(name: "Credit card", kind: .creditCard)
        store.saveWealthAccount(pension)
        store.saveWealthAccount(card)
        store.recordBalance(80_000, for: pension.id)
        store.recordBalance(1_000, for: card.id)
        XCTAssertEqual(store.netWorth, 79_000)
        XCTAssertTrue(store.staleWealthAccounts.isEmpty)

        let coffee = BankTransaction(date: Date(), merchant: "COSTA", amount: -3, fingerprint: "c")
        store.add(coffee)
        store.addNote(to: coffee, text: "Was this the meeting?")
        store.addNote(to: coffee, reaction: "👍")
        XCTAssertEqual(store.notes(for: coffee).count, 2)

        let reopened = BudgetStore(folder: folder)
        XCTAssertEqual(reopened.wealthAccounts.count, 2)
        XCTAssertEqual(reopened.notes.count, 2)
        XCTAssertTrue(reopened.syncRecords().contains { $0.collection == "wealth" })
        XCTAssertTrue(reopened.syncRecords().contains { $0.collection == "notes" })
    }

    func testCorrectionAppliesToSimilarPayments() {
        let store = BudgetStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let first = BankTransaction(date: Date(), merchant: "BIKANERVALA HOUNSLOW", amount: -16, fingerprint: "a")
        store.add(first)
        store.add(BankTransaction(date: Date(), merchant: "BIKANERVALA HOUNSLOW", amount: -18, fingerprint: "b"))
        XCTAssertEqual(store.similarUncategorised(to: first).count, 1)
        XCTAssertEqual(store.applyCategory("Eating out", toSimilar: first), 1)
    }
}

@MainActor
final class LockedFilesTests: XCTestCase {
    func testDamagedAndMissingAreDifferentFromNotYetReadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = JSONFileStorage(folder: folder)
        XCTAssertNil(try storage.loadChecked("missing.json") as [String]?)
        try Data("nope".utf8).write(to: folder.appendingPathComponent("bad.json"))
        XCTAssertThrowsError(try storage.loadChecked("bad.json") as [String]?) { error in
            guard case JSONFileStorage.LoadError.unreadable = error else { return XCTFail("\(error)") }
        }
        // A folder in place of a file can't be read: like a locked file, it isn't "damaged".
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("locked.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try storage.loadChecked("locked.json") as [String]?) { error in
            guard case JSONFileStorage.LoadError.locked = error else { return XCTFail("\(error)") }
        }
    }

    func testAStoreWaitingForItsFilesNeverOverwritesThem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("transactions.json"), withIntermediateDirectories: true)
        let store = BudgetStore(folder: folder)
        XCTAssertTrue(store.isWaitingForFiles)
        store.add(BankTransaction(date: Date(), merchant: "X", amount: -1, fingerprint: "x"))
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transactions.json").path, isDirectory: &isFolder) && isFolder.boolValue, "Nothing was written over it")
        XCTAssertTrue(store.unreadableFiles.isEmpty, "Not set aside as damaged")
    }
}
