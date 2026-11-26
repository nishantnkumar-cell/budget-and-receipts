import BudgetCore
import Foundation
import TaxCore

/// Property and tax details, saved in `tax-items.json` with the rest of the data (so they're
/// backed up) and synced as separate items. It runs even when the screens are switched off, so
/// another device's items are never lost.
@MainActor
final class TaxStore: ObservableObject, SyncSource {
    private static let file = "tax-items.json"

    @Published private(set) var book = PropertyBook()
    /// The tax year on screen. Starts on the one whose return is due next.
    @Published var year = TaxStore.dueYear(on: Date())

    private let storage: JSONFileStorage
    private var items = TaxItems()
    private(set) var role = HouseholdLink.Role.solo
    private(set) var unreadableFiles: [String] = []
    private(set) var isWaitingForFiles = false
    /// Called after a change made here is saved, so iCloud sync can send it.
    var didPersist: (() -> Void)?
    /// Items another device or your partner changed or deleted, for Recently changed.
    var didReceiveChanges: (([RecentChange]) -> Void)?
    /// Each payment's id and whether it's kept from the partner.
    var paymentPrivacy: () -> [String: Bool] = { [:] }

    let collections = TaxItems.collections

    init(folder: URL = JSONFileStorage.defaultFolder) {
        storage = JSONFileStorage(folder: folder)
        load()
    }

    /// A 2025-26 return is due online by 31 January 2027; after that, the next year's.
    nonisolated static func dueYear(on date: Date) -> TaxYear {
        TaxYear.supported.first { date < TaxYear.day($0.startYear + 2, 2, 1) } ?? TaxYear.supported.last!
    }

    /// Items saved here that this version can't read. They're kept, but missing from figures.
    var unreadableCount: Int { items.unreadableCount }

    // MARK: Changes made here

    func change(_ edit: (inout PropertyBook) -> Void) {
        guard !isWaitingForFiles else { return }
        var next = book
        edit(&next)
        guard next != book else { return }
        let privacy = paymentPrivacy()
        var updated = items
        updated.update(from: book, to: next) { privacy[$0] ?? false }
        replace(with: updated)
        save()
        didPersist?()
    }

    private func replace(with next: TaxItems) {
        items = next
        book = next.book
    }

    func resetAllData() {
        replace(with: TaxItems())
        save()
        didPersist?()
    }

    // MARK: Files

    private func load() {
        isWaitingForFiles = false
        unreadableFiles = []
        do {
            replace(with: TaxItems(try storage.loadChecked(Self.file) ?? []))
        } catch JSONFileStorage.LoadError.locked {
            isWaitingForFiles = true
        } catch {
            // Damaged: keep it aside, and let sync rebuild from iCloud instead of deleting.
            let url = storage.folder.appendingPathComponent(Self.file)
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
            replace(with: TaxItems())
            unreadableFiles = [Self.file]
        }
    }

    @discardableResult
    func reloadIfWaiting() -> Bool {
        guard isWaitingForFiles else { return true }
        load()
        return !isWaitingForFiles
    }

    func reloadAfterRestore() {
        load()
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
        let privacy = paymentPrivacy()
        let records = items.syncRecords { privacy[$0] }
        guard role == .member else { return records }
        return records.map { $0.isPrivate ? $0 : TaxItems.flipped($0) }
    }

    @discardableResult
    func applySync(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        guard !isWaitingForFiles else { return false }
        var mine = saves.filter { collections.contains($0.collection) }
        if role == .member { mine = mine.map { $0.isPrivate ? $0 : TaxItems.flipped($0) } }
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

    /// What arrivals are about to change or delete. Pay is left out: when someone stops
    /// sharing theirs, the other person mustn't be able to put it back.
    private func recentChanges(saves: [SyncRecord], deletes: Set<String>) -> [RecentChange] {
        let hidden: Set<String> = [TaxItems.Kind.pay.rawValue, TaxItems.Kind.carried.rawValue]
        let before = Dictionary(items.records.filter { !hidden.contains($0.collection) }.map { ($0.key, $0) },
                                uniquingKeysWith: { first, _ in first })
        var kept: [RecentChange] = []
        for key in deletes {
            guard let old = before[key] else { continue }
            kept.append(RecentChange(kind: .deleted, byPartner: false, collection: old.collection, itemID: old.id,
                                     previous: old.payload, summary: summary(of: old)))
        }
        for save in saves {
            guard let old = before[save.key], old.payload != save.payload else { continue }
            kept.append(RecentChange(kind: .changed, byPartner: save.byPartner, collection: old.collection, itemID: old.id,
                                     previous: old.payload, summary: summary(of: old)))
        }
        return kept
    }

    private func summary(of record: SyncRecord) -> String {
        let one = TaxItems([record]).book
        if let property = one.properties.first { return "Property \(property.name)" }
        if let rule = one.rules.first { return "Property rule for \(rule.merchantContains)" }
        if let statement = one.statements.first { return "Agent statement of \(PropertyLedger.day(statement.date))" }
        if let interest = one.interest.first { return "Mortgage interest for \(interest.taxYear)" }
        return "A property payment choice"
    }

    /// Puts an item back as it was before the change or deletion, everywhere.
    func restore(_ change: RecentChange) {
        guard !isWaitingForFiles, collections.contains(change.collection) else { return }
        let privacy = paymentPrivacy()
        var next = items
        next.restore(SyncRecord(collection: change.collection, id: change.itemID, payload: change.previous)) { privacy[$0] ?? false }
        replace(with: next)
        save()
        didPersist?()
    }
}
