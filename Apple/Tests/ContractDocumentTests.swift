import BudgetCore
import CoreGraphics
import XCTest
@testable import BudgetReceipts

/// Contract documents are kept with their contract, go to iCloud as encrypted files, and are
/// deleted with it.
@MainActor
final class ContractDocumentTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func samplePDF() -> Data {
        let image = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return ContractDocumentStore.pdf(from: [image, image])!
    }

    private func contract(private isPrivate: Bool = false) -> SubscriptionContract {
        var item = SubscriptionContract.blank(.contract)
        item.vendor = "Vodafone"
        item.isPrivate = isPrivate
        return item
    }

    func testDocumentSyncsAsAFileAndFollowsPrivacy() throws {
        let store = SubscriptionStore(folder: folder)
        let name = try store.documentFiles.save(samplePDF(), isPDF: true)
        var item = contract(private: true)
        item.documents = [ContractDocument(fileName: name, title: "Signed contract")]
        store.save(item)
        let file = try XCTUnwrap(store.syncRecords().first { $0.collection == "contractFiles" })
        XCTAssertEqual(file.fileName, name)
        XCTAssertTrue(file.isPrivate)
        XCTAssertTrue(CloudSync.isSafeImageName(name))
        XCTAssertNotNil(CloudSync.fileForUpload(store.documentFiles.folder.appendingPathComponent(name)))
    }

    func testDeletingTheContractDeletesItsFiles() throws {
        let store = SubscriptionStore(folder: folder)
        let name = try store.documentFiles.save(samplePDF(), isPDF: true)
        var item = contract()
        let document = ContractDocument(fileName: name, title: "Contract")
        item.documents = [document]
        store.save(item)
        store.delete(item)
        XCTAssertNil(store.documentFiles.url(for: document))
        XCTAssertFalse(store.syncRecords().contains { $0.collection == "contractFiles" })
    }

    func testUnsavedFilesAreClearedOnNextLaunch() throws {
        let store = SubscriptionStore(folder: folder)
        let kept = ContractDocument(fileName: try store.documentFiles.save(samplePDF(), isPDF: true), title: "Kept")
        let dropped = ContractDocument(fileName: try store.documentFiles.save(samplePDF(), isPDF: true), title: "Dropped")
        store.noteUnsaved(kept)
        store.noteUnsaved(dropped)
        var item = contract()
        item.documents = [kept]
        store.save(item)
        let relaunched = SubscriptionStore(folder: folder)
        XCTAssertNotNil(relaunched.documentFiles.url(for: kept))
        XCTAssertNil(relaunched.documentFiles.url(for: dropped))
    }

    func testNotAPDFIsRefused() {
        XCTAssertThrowsError(try SubscriptionStore(folder: folder).documentFiles.save(Data("hello".utf8), isPDF: true))
    }
}
