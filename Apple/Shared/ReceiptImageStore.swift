import Foundation

/// Keeps a private copy of each receipt image next to the app's data, so the receipt
/// can be looked at again after the split is approved.
struct ReceiptImageStore {
    let folder: URL

    init(dataFolder: URL = JSONFileStorage.defaultFolder) {
        folder = dataFolder.appendingPathComponent("Receipts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Saves image data and returns the file name to keep in `ReceiptRecord.imagePath`.
    func save(_ data: Data, fileExtension: String = "jpg") throws -> String {
        let name = "\(UUID().uuidString).\(fileExtension.lowercased())"
        #if os(iOS)
        try data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        #endif
        return name
    }

    func url(for imagePath: String) -> URL? {
        guard !imagePath.isEmpty else { return nil }
        let url = folder.appendingPathComponent((imagePath as NSString).lastPathComponent)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
