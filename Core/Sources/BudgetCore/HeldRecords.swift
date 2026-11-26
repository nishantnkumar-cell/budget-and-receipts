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
    /// A held copy of a known item is dropped too: its own store now has something newer.
    /// Returns true when something changed.
    @discardableResult
    public mutating func apply(saves: [SyncRecord], deletes: Set<String>, known: Set<String>) -> Bool {
        let before = byKey
        for key in deletes { byKey[key] = nil }
        for record in saves { byKey[record.key] = known.contains(record.collection) ? nil : record }
        return byKey != before
    }

    /// After a backup is restored: its items win, and any it doesn't mention stay, so that
    /// restoring never deletes something this version can't even show.
    public func restored(from backup: HeldRecords) -> HeldRecords {
        HeldRecords(records + backup.records)
    }

    /// When this device starts seeing a household from the other side. Shared items of an
    /// unknown kind can't be turned round, so they're let go rather than sent back mirrored;
    /// a device that understands them sends its own.
    public mutating func removeShared() {
        byKey = byKey.filter { $0.value.isPrivate }
    }

    /// The held items belonging to these collections, for a store that now understands them.
    public func records(in collections: Set<String>) -> [SyncRecord] {
        records.filter { collections.contains($0.collection) }
    }

    public mutating func remove(_ keys: some Sequence<String>) {
        for key in keys { byKey[key] = nil }
    }
}
