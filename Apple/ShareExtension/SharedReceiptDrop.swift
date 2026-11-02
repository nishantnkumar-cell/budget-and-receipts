import Foundation

/// A folder both the app and its share extension can reach (an App Group). The extension
/// only copies shared receipts and bank statements in here; the app reads them when it opens.
enum SharedReceiptDrop {
    #if os(macOS)
    // On the Mac a team-prefixed group needs no provisioning profile.
    static let appGroup = "VCWH3ZCZ5J.com.nishantkumar.budgetreceipts"
    #else
    static let appGroup = "group.com.nishantkumar.budgetreceipts"
    #endif
    static let receiptTypes: Set<String> = ["pdf", "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
    static let statementTypes: Set<String> = ["csv", "ofx", "qfx", "qif"]
    static var fileTypes: Set<String> { receiptTypes.union(statementTypes) }

    /// Bigger files are refused: statements and receipts are far smaller, and the share
    /// extension has little memory.
    static let maxFileBytes = 20_000_000

    static func isTooLarge(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > maxFileBytes
    }

    static func isStatement(_ url: URL) -> Bool { statementTypes.contains(url.pathExtension.lowercased()) }

    /// Nil when the App Group is missing, e.g. in an unsigned test build.
    static var folder: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let folder = container.appendingPathComponent("SharedReceipts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies a shared file into the drop folder. Returns false for unsupported types.
    @discardableResult
    static func add(_ data: Data, fileExtension: String, to folder: URL? = folder) throws -> Bool {
        let ext = fileExtension.lowercased()
        guard fileTypes.contains(ext), let folder else { return false }
        let url = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return true
    }

    /// Files waiting to be read, oldest first.
    static func waitingFiles(in folder: URL? = folder) -> [URL] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return files
            .filter { fileTypes.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return l < r
            }
    }
}
