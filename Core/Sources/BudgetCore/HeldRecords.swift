import Foundation

/// Items from iCloud that this version of the app doesn't understand, such as something a newer
/// version added. They're kept exactly as they arrived and handed back to sync, so an older
/// version never mistakes them for deleted items. A version that does understand them takes
/// them over.
public struct HeldRecords: Hashable, Sendable {
    private var byKey: [String: SyncRecord]

    public init(_ records: [SyncRecord] = []) {
        byKey = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// In a fixed order, so the same items are saved the same way.
    public var records: [SyncRecord] { byKey.values.sorted { $0.key < $1.key } }
    public var isEmpty: Bool { byKey.isEmpty }

    /// Takes in what arrived: keeps items outside `known` collections and drops deleted ones.
    /// Returns true when something changed.
    @discardableResult
    public mutating func apply(saves: [SyncRecord], deletes: Set<String>, known: Set<String>) -> Bool {
        let before = byKey
        for key in deletes { byKey[key] = nil }
        for record in saves where !known.contains(record.collection) { byKey[record.key] = record }
        return byKey != before
    }

    /// The held items belonging to these collections, for a store that now understands them.
    public func records(in collections: Set<String>) -> [SyncRecord] {
        records.filter { collections.contains($0.collection) }
    }

    public mutating func remove(_ keys: some Sequence<String>) {
        for key in keys { byKey[key] = nil }
    }
}
