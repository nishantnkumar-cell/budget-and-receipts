import Foundation

/// One item as it travels to iCloud: a transaction, a budget, a receipt image and so on.
/// The payload is the item's JSON, so every app (and later Windows) reads the same thing.
public struct SyncRecord: Hashable, Sendable {
    public var collection: String
    public var id: String
    public var payload: Data
    /// Private items stay in the owner's private zone; everything else is shared with the household.
    public var isPrivate: Bool
    /// A file that goes with the record, such as a receipt photo.
    public var fileName: String?
    /// Arrived from iCloud last changed by someone else (the partner), not by this person.
    public var byPartner = false

    public init(collection: String, id: String, payload: Data, isPrivate: Bool = false, fileName: String? = nil) {
        self.collection = collection
        self.id = id
        self.payload = payload
        self.isPrivate = isPrivate
        self.fileName = fileName
    }

    /// Unique across collections; also the iCloud record name.
    public var key: String { Self.key(collection, id) }
    public static func key(_ collection: String, _ id: String) -> String { "\(collection)|\(id)" }

    /// A stable fingerprint of the payload (FNV-1a), to notice changes without keeping copies.
    public var digest: UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in payload {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return isPrivate ? hash ^ 1 : hash
    }

    /// Encodes items the same way on every device: sorted keys, ISO dates.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func records<T: Encodable>(_ items: [T], collection: String, id: (T) -> String, isPrivate: (T) -> Bool = { _ in false }) -> [SyncRecord] {
        let encoder = encoder()
        return items.compactMap { item in
            guard let data = try? encoder.encode(item) else { return nil }
            return SyncRecord(collection: collection, id: id(item), payload: data, isPrivate: isPrivate(item))
        }
    }
}

/// What has been sent to (or received from) iCloud, so only real changes are sent.
public struct SyncState: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var digest: UInt64
        public var isPrivate: Bool
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// The changes between what was last synced and the items as they are now.
    /// An item that became private (or shared) is deleted from its old zone and saved in the new one.
    public func changes(to current: [SyncRecord]) -> SyncChanges {
        var saves: [SyncRecord] = []
        var deletes: [SyncChanges.Delete] = []
        var seen = Set<String>()
        for record in current {
            seen.insert(record.key)
            guard let entry = entries[record.key] else { saves.append(record); continue }
            if entry.isPrivate != record.isPrivate {
                deletes.append(.init(key: record.key, isPrivate: entry.isPrivate))
                saves.append(record)
            } else if entry.digest != record.digest {
                saves.append(record)
            }
        }
        for (key, entry) in entries where !seen.contains(key) {
            deletes.append(.init(key: key, isPrivate: entry.isPrivate))
        }
        return SyncChanges(saves: saves, deletes: deletes.sorted { $0.key < $1.key })
    }

    public mutating func recordSaved(_ record: SyncRecord) {
        entries[record.key] = Entry(digest: record.digest, isPrivate: record.isPrivate)
    }

    public mutating func recordDeleted(_ key: String) {
        entries[key] = nil
    }
}

public struct SyncChanges: Hashable, Sendable {
    public struct Delete: Hashable, Sendable {
        public var key: String
        public var isPrivate: Bool
    }

    public var saves: [SyncRecord]
    public var deletes: [Delete]
    public var isEmpty: Bool { saves.isEmpty && deletes.isEmpty }
}

/// Applies records that arrived from iCloud to a local list. Arrivals replace the local copy
/// with the same id; deletions remove it. Items that fail to decode are skipped.
public enum SyncMerge {
    public static func apply<T: Decodable>(
        saves: [SyncRecord],
        deletes: Set<String>,
        to items: [T],
        collection: String,
        id: (T) -> String
    ) -> [T] {
        let decoder = SyncRecord.decoder()
        var result = items.filter { !deletes.contains(SyncRecord.key(collection, id($0))) }
        for record in saves where record.collection == collection {
            guard let item = try? decoder.decode(T.self, from: record.payload) else { continue }
            if let index = result.firstIndex(where: { id($0) == record.id }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
}
