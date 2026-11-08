import CommonCrypto
import CryptoKit
import Foundation

/// A password-protected copy of everything: payments, budgets, contracts, receipts and their
/// photos, in one file you keep where you like. It's encrypted on this device with AES-256-GCM,
/// using a key made from your password (PBKDF2-SHA256, 600,000 rounds), so the file is useless
/// without the password, and the password can't be recovered.
///
/// File layout: "DUOBACKUP1" · 16-byte salt · rounds (UInt32, big-endian) · AES-GCM sealed box
/// (nonce, ciphertext, tag) of the LZFSE-compressed archive. The archive is a JSON manifest
/// (its length first, UInt32 big-endian) followed by each file's bytes in manifest order.
enum EncryptedBackup {
    static let magic = Data("DUOBACKUP1".utf8)
    static let rounds: UInt32 = 600_000
    static let fileExtension = "duobackup"
    static let minimumPasswordLength = 8

    struct Manifest: Codable {
        struct Entry: Codable {
            var path: String
            var size: Int
        }
        var created: Date
        var device: String
        var appVersion: String
        var files: [Entry]
    }

    /// What a backup holds, shown before anything is replaced.
    struct Contents {
        var manifest: Manifest
        var files: [String: Data]

        var transactionCount: Int { count("transactions.json") }
        var budgetCount: Int { count("budgets.json") }
        var contractCount: Int { count("subscriptions.json") }
        var photoCount: Int { files.keys.filter { $0.hasPrefix("Receipts/") }.count }

        private func count(_ name: String) -> Int {
            guard let data = files[name], let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
            return array.count
        }
    }

    enum Failure: LocalizedError {
        case notABackup, wrongPassword, damaged, passwordTooShort

        var errorDescription: String? {
            switch self {
            case .notABackup: "This isn't a Duo Budget backup file."
            case .wrongPassword: "That password doesn't open this backup."
            case .damaged: "The backup file is damaged and can't be read."
            case .passwordTooShort: "Use a password of at least \(EncryptedBackup.minimumPasswordLength) characters."
            }
        }
    }

    // MARK: Which files

    /// Files that describe this device's iCloud connection, not your data: never backed up or restored.
    static func isDeviceState(_ name: String) -> Bool {
        name.hasPrefix("sync-") || name == "household.json" || name.contains(".unreadable-")
    }

    /// Your data in the app's folder: its JSON files and the receipt photos and contract documents.
    static func dataFiles(in folder: URL) -> [String] {
        let manager = FileManager.default
        let top = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !isDeviceState($0) }
        let receipts = ((try? manager.contentsOfDirectory(atPath: folder.appendingPathComponent("Receipts").path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { "Receipts/" + $0 }
        return (top + receipts).sorted()
    }

    // MARK: Making one

    static func make(folder: URL, password: String, device: String, appVersion: String, now: Date = Date()) throws -> Data {
        guard password.count >= minimumPasswordLength else { throw Failure.passwordTooShort }
        var entries: [Manifest.Entry] = []
        var body = Data()
        for path in dataFiles(in: folder) {
            let data = try Data(contentsOf: folder.appendingPathComponent(path))
            entries.append(.init(path: path, size: data.count))
            body.append(data)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifest = try encoder.encode(Manifest(created: now, device: device, appVersion: appVersion, files: entries))
        var archive = bigEndian(UInt32(manifest.count))
        archive.append(manifest)
        archive.append(body)
        let compressed = try (archive as NSData).compressed(using: .lzfse) as Data

        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.damaged }
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        guard let sealed = try AES.GCM.seal(compressed, using: key, authenticating: magic).combined else { throw Failure.damaged }

        var file = magic
        file.append(salt)
        file.append(bigEndian(rounds))
        file.append(sealed)
        return file
    }

    // MARK: Opening one

    static func open(_ file: Data, password: String) throws -> Contents {
        let header = magic.count + 16 + 4
        guard file.count > header, file.prefix(magic.count) == magic else { throw Failure.notABackup }
        let salt = file.subdata(in: magic.count..<magic.count + 16)
        let rounds = file.subdata(in: magic.count + 16..<header).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard rounds >= 100_000, rounds <= 10_000_000 else { throw Failure.damaged }
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        let compressed: Data
        do {
            compressed = try AES.GCM.open(AES.GCM.SealedBox(combined: file.subdata(in: header..<file.count)), using: key, authenticating: magic)
        } catch {
            throw Failure.wrongPassword
        }
        guard let archive = try? (compressed as NSData).decompressed(using: .lzfse) as Data, archive.count >= 4 else { throw Failure.damaged }
        let manifestLength = Int(archive.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard archive.count >= 4 + manifestLength else { throw Failure.damaged }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: archive.subdata(in: 4..<4 + manifestLength)) else { throw Failure.damaged }
        var files: [String: Data] = [:]
        var offset = 4 + manifestLength
        for entry in manifest.files {
            guard entry.size >= 0, offset + entry.size <= archive.count, isSafe(entry.path) else { throw Failure.damaged }
            files[entry.path] = archive.subdata(in: offset..<offset + entry.size)
            offset += entry.size
        }
        return Contents(manifest: manifest, files: files)
    }

    /// Only plain names at the top, or in Receipts/: a damaged or crafted file can't write elsewhere.
    static func isSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return false }
        switch parts.count {
        case 1: return path.hasSuffix(".json") && !isDeviceState(path)
        case 2: return parts[0] == "Receipts"
        default: return false
        }
    }

    // MARK: Restoring

    /// Replaces the data in `folder` with the backup's: data files not in the backup are
    /// removed, so what's left is exactly the backup. iCloud connection files are kept.
    static func replace(folder: URL, with contents: Contents) throws {
        let manager = FileManager.default
        let receipts = folder.appendingPathComponent("Receipts", isDirectory: true)
        try manager.createDirectory(at: receipts, withIntermediateDirectories: true)
        // Written next to the data first, so a failure part-way leaves the current data alone.
        let staging = folder.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging.appendingPathComponent("Receipts"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        for (path, data) in contents.files {
            try data.write(to: staging.appendingPathComponent(path), options: JSONFileStorage.writeOptions)
        }
        for path in dataFiles(in: folder) { try manager.removeItem(at: folder.appendingPathComponent(path)) }
        for path in contents.files.keys {
            try manager.moveItem(at: staging.appendingPathComponent(path), to: folder.appendingPathComponent(path))
        }
    }

    // MARK: Helpers

    private static func deriveKey(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let passwordData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), passwordData.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.damaged }
        return SymmetricKey(data: key)
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
