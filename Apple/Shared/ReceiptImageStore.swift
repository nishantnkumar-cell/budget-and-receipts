import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps a private copy of each receipt image next to the app's data, so the receipt
/// can be looked at again after the split is approved.
struct ReceiptImageStore {
    let folder: URL

    init(dataFolder: URL = JSONFileStorage.defaultFolder) {
        folder = dataFolder.appendingPathComponent("Receipts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static var writeOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }

    /// Saves image data and returns the file name to keep in `ReceiptRecord.imagePath`.
    /// Photos are re-encoded without their metadata first, so no location, time or camera
    /// details are kept or synced. A file that isn't an image is kept as it is.
    func save(_ data: Data, fileExtension: String = "jpg") throws -> String {
        let clean = Self.withoutMetadata(data)
        let name = "\(UUID().uuidString).\(clean == nil ? fileExtension.lowercased() : "jpg")"
        try (clean ?? data).write(to: folder.appendingPathComponent(name), options: Self.writeOptions)
        return name
    }

    /// The image as a JPEG with no EXIF, GPS or other properties, the right way up. Nil when
    /// the data isn't an image.
    static func withoutMetadata(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    func url(for imagePath: String) -> URL? {
        guard !imagePath.isEmpty else { return nil }
        let url = folder.appendingPathComponent((imagePath as NSString).lastPathComponent)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
