import BudgetCore
import XCTest
@testable import BudgetReceipts

final class CloudSyncTests: XCTestCase {
    func testRecordNamesGiveNothingAway() {
        let key = SyncRecord.key("transactions", "stmt:2026-10-03|-12.40|TESCO STORES|1")
        let name = CloudSync.recordName(key)
        XCTAssertEqual(name.count, 32)
        XCTAssertFalse(name.contains("TESCO") || name.contains("12.40"))
        XCTAssertEqual(name, CloudSync.recordName(key), "The same item always gets the same name")
        XCTAssertNotEqual(name, CloudSync.recordName(SyncRecord.key("transactions", "other")))
    }

    func testLargePhotosAreShrunkToFitAnEncryptedField() throws {
        let size = 3000
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<300 {
            context.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 11) / 11, blue: CGFloat(i % 13) / 13, alpha: 1))
            context.fill(CGRect(x: (i * 37) % size, y: (i * 53) % size, width: 211, height: 197))
        }
        let image = context.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        defer { try? FileManager.default.removeItem(at: url) }
        let upload = try XCTUnwrap(CloudSync.imageForUpload(url))
        XCTAssertLessThanOrEqual(upload.count, CloudSync.maxImageBytes)
        XCTAssertNil(CloudSync.imageForUpload(url.appendingPathExtension("missing")))
    }
}

final class CloudSyncPermissionTests: XCTestCase {
    func testWithoutAProfileGrantingICloudSyncStaysOff() {
        // Test builds have no provisioning profile with iCloud: the app must not touch CloudKit.
        XCTAssertFalse(CloudSync.isSigned(for: "iCloud.com.nishantkumar.budgetreceipts"))
        XCTAssertNil(CloudSync.containerID)
    }
}
