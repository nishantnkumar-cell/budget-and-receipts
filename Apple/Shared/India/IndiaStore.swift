import BudgetCore
import Foundation
import TaxCore

/// Rupee accounts in India, saved in `india-items.json` with the rest of the data (so they're
/// backed up) and synced as separate items. It runs even when the screens are switched off, so
/// another device's items are never lost. Nothing here is added to the budget's own figures.
@MainActor
final class IndiaStore: ObservableObject, SyncSource {
    private static let file = "india-items.json"

    @Published private(set) var book = IndiaBook()
    /// The tax year on the interest screen.
    @Published var year = TaxStore.dueYear(on: Date())

    private let storage: JSONFileStorage
    private var items = IndiaItems()
    private(set) var role = HouseholdLink.Role.solo
    private(set) var unreadableFiles: [String] = []
    private(set) var isWaitingForFiles = false
    /// Called after a change made here is saved, so iCloud sync can send it.
    var didPersist: (() -> Void)?
    /// Items another device or your partner changed or deleted, for Recently changed.
    var didReceiveChanges: (([RecentChange]) -> Void)?

    let collections = IndiaItems.collections
    /// A partner's changes to items held privately here, turned down in the last arrivals.
    private var lastRejected: Set<String> = []

    init(folder: URL = JSONFileStorage.defaultFolder) {
        storage = JSONFileStorage(folder: folder)
        load()
    }

    /// Items saved here that this version can't read. They're kept, but missing from figures.
    var unreadableCount: Int { items.unreadableCount }

    // MARK: Changes made here

    func change(_ edit: (inout IndiaBook) -> Void) {
        guard !isWaitingForFiles else { return }
        var next = book
        edit(&next)
        guard next != book else { return }
        var updated = items
        updated.update(from: book, to: next)
        replace(with: updated)
        save()
        didPersist?()
    }

    private func replace(with next: IndiaItems) {
        items = next
        book = next.book
    }

    func resetAllData() {
        replace(with: IndiaItems())
        save()
        didPersist?()
    }

    // MARK: Files

    private func load() {
        isWaitingForFiles = false
        unreadableFiles = []
        do {
            replace(with: IndiaItems(try storage.loadChecked(Self.file) ?? []))
        } catch JSONFileStorage.LoadError.locked {
            isWaitingForFiles = true
        } catch {
            // Damaged: keep it aside, and let sync rebuild from iCloud instead of deleting.
            let url = storage.folder.appendingPathComponent(Self.file)
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
            replace(with: IndiaItems())
            unreadableFiles = [Self.file]
        }
    }

    @discardableResult
    func reloadIfWaiting() -> Bool {
        guard isWaitingForFiles else { return true }
        load()
        return !isWaitingForFiles
    }

    /// A backup with no India file (one made before it existed) leaves the accounts as they
    /// are, rather than deleting them everywhere.
    func reloadAfterRestore() {
        let current = items
        load()
        if !FileManager.default.fileExists(atPath: storage.folder.appendingPathComponent(Self.file).path) && unreadableFiles.isEmpty {
            replace(with: current)
        }
        save()
        didPersist?()
    }

    @discardableResult
    private func save() -> Bool {
        guard !isWaitingForFiles else { return false }
        // Nothing entered and no file: don't create one.
        if items.isEmpty && !FileManager.default.fileExists(atPath: storage.folder.appendingPathComponent(Self.file).path) { return true }
        return storage.save(items.records, Self.file)
    }

    // MARK: Sync

    func setHouseholdRole(_ role: HouseholdLink.Role) { self.role = role }

    /// Shared items go out from the household owner's point of view.
    func syncRecords() -> [SyncRecord] {
        let records = items.syncRecords()
        guard role == .member else { return records }
        return records.map { $0.isPrivate ? $0 : IndiaItems.flipped($0) }
    }

    @discardableResult
    func applySync(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        lastRejected = []
        guard !isWaitingForFiles else { return false }
        var mine = saves.filter { collections.contains($0.collection) }
        // A partner's change to something held privately here is turned down. Only the owner
        // can tell a partner's change from one made on their own other device.
        lastRejected = Set(mine.filter { save in
            role == .owner && save.byPartner && !save.isPrivate && items.holdsPrivately(save.key)
        }.map(\.key))
        mine.removeAll { lastRejected.contains($0.key) }
        if role == .member { mine = mine.map { $0.isPrivate ? $0 : IndiaItems.flipped($0) } }
        var next = items
        guard next.apply(saves: mine, deletes: deletes) else { return true }
        let previous = items
        let changes = recentChanges(saves: mine, deletes: deletes)
        replace(with: next)
        guard save() else {
            replace(with: previous)
            return false
        }
        if !changes.isEmpty { didReceiveChanges?(changes) }
        return true
    }

    func rejectedKeys(_ saves: [SyncRecord]) -> Set<String> { lastRejected }

    /// What arrivals are about to change or delete. In a shared household only your own
    /// accounts are listed: when your partner stops sharing theirs (or a joint one they now
    /// keep private), you mustn't be able to put it back.
    private func recentChanges(saves: [SyncRecord], deletes: Set<String>) -> [RecentChange] {
        let before = Dictionary(items.records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [RecentChange] = []
        for key in deletes {
            guard let old = before[key], mayList(old) else { continue }
            kept.append(RecentChange(kind: .deleted, byPartner: false, collection: old.collection, itemID: old.id,
                                     previous: old.payload, summary: summary(of: old)))
        }
        for save in saves {
            guard let old = before[save.key], old.payload != save.payload, mayList(old) else { continue }
            kept.append(RecentChange(kind: .changed, byPartner: save.byPartner, collection: old.collection, itemID: old.id,
                                     previous: old.payload, summary: summary(of: old)))
        }
        return kept
    }

    private func mayList(_ record: SyncRecord) -> Bool {
        guard role != .solo else { return true }
        let one = IndiaItems([record]).book
        if let account = one.accounts.first { return account.owner == .mine }
        if let entry = one.entries.first { return book.account(entry.accountID)?.owner == .mine }
        return !one.rates.isEmpty
    }

    private func summary(of record: SyncRecord) -> String {
        let one = IndiaItems([record]).book
        if let account = one.accounts.first { return "Indian account \(account.title)" }
        if let entry = one.entries.first { return "Rupee line of \(PropertyLedger.day(entry.date))" }
        if let rate = one.rates.first { return "Rupee exchange rate (\(rate.id))" }
        return "Something in India Accounts"
    }

    /// Puts items back as they were before being changed or deleted, everywhere. Accounts go
    /// first, so their lines come back as private or shared as the account.
    func restore(_ changes: [RecentChange]) {
        guard !isWaitingForFiles else { return }
        let ours = changes.filter { collections.contains($0.collection) }
        let accounts = IndiaItems.Kind.account.rawValue
        var next = items
        for change in ours.filter({ $0.collection == accounts }) + ours.filter({ $0.collection != accounts }) {
            next.restore(SyncRecord(collection: change.collection, id: change.itemID, payload: change.previous))
        }
        guard next.records != items.records else { return }
        replace(with: next)
        save()
        didPersist?()
    }
}
