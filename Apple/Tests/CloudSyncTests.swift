import BudgetCore
import XCTest
@testable import BudgetReceipts

final class CloudSyncTests: XCTestCase {
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

    func testOnlyTheAppsOwnPhotoNamesAreAccepted() {
        XCTAssertTrue(CloudSync.isSafeImageName("3F2504E0-4F89-11D3-9A0C-0305E82C3301.jpg"))
        XCTAssertFalse(CloudSync.isSafeImageName("../sync-state.json"))
        XCTAssertFalse(CloudSync.isSafeImageName("3F2504E0-4F89-11D3-9A0C-0305E82C3301.json"))
    }
}
