import BudgetCore
import Foundation

/// The rupee accounts as separate synced items, one for each account, line and rate, held from
/// this person's point of view (see `TaxItems`).
public struct IndiaItems: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case account = "indiaAccounts", entry = "indiaEntries", rate = "indiaRates"
    }

    public static let collections = Set(Kind.allCases.map(\.rawValue))

    private var byKey: [String: SyncRecord]

    public init(_ records: [SyncRecord] = []) {
        byKey = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// In a fixed order, so the same items are saved the same way.
    public var records: [SyncRecord] { byKey.values.sorted { $0.key < $1.key } }
    public var isEmpty: Bool { byKey.isEmpty }

    private static func decode<T: Decodable>(_ type: T.Type, _ record: SyncRecord) -> T? {
        try? SyncRecord.decoder().decode(type, from: record.payload)
    }

    /// What the items say. One this version can't read is kept but not shown.
    public var book: IndiaBook {
        let decoder = SyncRecord.decoder()
        func all<T: Decodable>(_ kind: Kind) -> [T] {
            records.filter { $0.collection == kind.rawValue }.compactMap { try? decoder.decode(T.self, from: $0.payload) }
        }
        let accounts: [IndiaAccount] = all(.account)
        return IndiaBook(accounts: accounts.sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) },
                         entries: all(.entry), rates: all(.rate))
    }

    public var unreadableCount: Int {
        let book = book
        return records.count - book.accounts.count - book.entries.count - book.rates.count
    }

    /// One record per item. A line is as private as its account, and private when the account
    /// isn't there to ask.
    static func records(for book: IndiaBook) -> [SyncRecord] {
        let privacy = Dictionary(book.accounts.map { ($0.id, $0.isPrivate) }, uniquingKeysWith: { _, last in last })
        return SyncRecord.records(book.accounts, collection: Kind.account.rawValue, id: \.id, isPrivate: \.isPrivate)
            + SyncRecord.records(book.entries, collection: Kind.entry.rawValue, id: \.id, isPrivate: { privacy[$0.accountID] ?? true })
            + SyncRecord.records(book.rates, collection: Kind.rate.rawValue, id: \.id)
    }

    /// Saves what the person changed. Items they didn't touch stay exactly as stored,
    /// including anything a newer version added to them.
    public mutating func update(from old: IndiaBook, to new: IndiaBook) {
        func index(_ book: IndiaBook) -> [String: SyncRecord] {
            Dictionary(Self.records(for: book).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        }
        let before = index(old), after = index(new)
        // Accounts whose privacy this edit changed: only that may share a private line again.
        let wasPrivate = Dictionary(old.accounts.map { ($0.id, $0.isPrivate) }, uniquingKeysWith: { _, last in last })
        let changed = Set(new.accounts.filter { account in wasPrivate[account.id].map { $0 != account.isPrivate } ?? false }.map(\.id))

        for key in before.keys where after[key] == nil { byKey[key] = nil }
        for (key, record) in after where before[key] != record {
            var record = record
            if record.collection == Kind.entry.rawValue, let stored = byKey[key],
               let entry = Self.decode(IndiaEntry.self, record), !changed.contains(entry.accountID) {
                // Editing a line never widens who sees it, and doesn't narrow it by guessing
                // when its account isn't here.
                if stored.isPrivate {
                    record.isPrivate = true
                } else if new.account(entry.accountID) == nil {
                    record.isPrivate = false
                }
            }
            byKey[key] = record
        }
        // Every line of an account whose privacy changed follows it, edited or not.
        for (key, record) in byKey where record.collection == Kind.entry.rawValue {
            guard let entry = Self.decode(IndiaEntry.self, record), changed.contains(entry.accountID),
                  let account = new.account(entry.accountID) else { continue }
            byKey[key]?.isPrivate = account.isPrivate
        }
    }

    /// Takes in what arrived from your other devices or your partner.
    public mutating func apply(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        let before = byKey
        for key in deletes { byKey[key] = nil }
        for record in saves where Self.collections.contains(record.collection) {
            var record = record
            record.byPartner = false
            byKey[record.key] = record
        }
        return byKey != before
    }

    /// Puts an earlier version of an item back. A line takes its account's privacy, and stays
    /// private when the account isn't here.
    public mutating func restore(_ record: SyncRecord) {
        var record = record
        switch Kind(rawValue: record.collection) {
        case .account: record.isPrivate = Self.decode(IndiaAccount.self, record)?.isPrivate ?? true
        case .entry:
            let owner = Self.decode(IndiaEntry.self, record).flatMap { book.account($0.accountID) }
            record.isPrivate = owner?.isPrivate ?? true
        case .rate, nil: record.isPrivate = false
        }
        byKey[record.key] = record
    }

    /// The items to send. A line of an account that is private now goes privately at once; one
    /// held as private stays so until you share its account (see `update`), so a device that
    /// hasn't caught up can't share it.
    public func syncRecords() -> [SyncRecord] {
        let privateAccounts = Set(book.accounts.filter(\.isPrivate).map(\.id))
        return records.map { record in
            var record = record
            if record.collection == Kind.entry.rawValue, let entry = Self.decode(IndiaEntry.self, record),
               privateAccounts.contains(entry.accountID) {
                record.isPrivate = true
            }
            return record
        }
    }

    /// True when this account or line is held privately here.
    public func holdsPrivately(_ key: String) -> Bool { byKey[key]?.isPrivate ?? false }

    /// The same item seen from the other person's side of a shared household: "mine" and
    /// "partner" swap. Turning it twice gives it back.
    public static func flipped(_ record: SyncRecord) -> SyncRecord {
        guard Kind(rawValue: record.collection) == .account, var account = decode(IndiaAccount.self, record) else { return record }
        account.owner = switch account.owner {
        case .mine: .partner
        case .partner: .mine
        case .shared: .shared
        }
        guard let payload = try? SyncRecord.encoder().encode(account) else { return record }
        var result = record
        result.payload = payload
        return result
    }
}
