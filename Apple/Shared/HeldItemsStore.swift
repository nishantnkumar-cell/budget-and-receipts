import BudgetCore
import Foundation

/// Keeps synced items this version of the app doesn't understand (see `HeldRecords`), in
/// `held-items.json` with the rest of the data, so they're backed up and restored too.
@MainActor
final class HeldItemsStore: ObservableObject, SyncSource {
    private static let file = "held-items.json"

    private let storage: JSONFileStorage
    /// The kinds of item the other stores understand.
    private let known: Set<String>
    private var held = HeldRecords()
    private(set) var unreadableFiles: [String] = []
    private(set) var isWaitingForFiles = false
    var didPersist: (() -> Void)?

    /// Holds nothing as its own kind: it takes whatever no other store claims.
    let collections: Set<String> = []

    init(folder: URL = JSONFileStorage.defaultFolder, known: Set<String>) {
        storage = JSONFileStorage(folder: folder)
        self.known = known
        load()
    }

    private func load() {
        isWaitingForFiles = false
        unreadableFiles = []
        do {
            held = HeldRecords(try storage.loadChecked(Self.file) ?? [])
        } catch JSONFileStorage.LoadError.locked {
            isWaitingForFiles = true
        } catch {
            // Damaged: keep it aside, and let sync rebuild from iCloud instead of deleting.
            let url = storage.folder.appendingPathComponent(Self.file)
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
            held = HeldRecords()
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
        let current = held
        load()
        held = current.restored(from: held)
        save()
        didPersist?()
    }

    /// This device joined or left a partner's household (see `HeldRecords.removeShared`).
    func removeSharedItems() {
        held.removeShared()
        save()
    }

    func resetAllData() {
        held = HeldRecords()
        save()
        didPersist?()
    }

    func setHouseholdRole(_ role: HouseholdLink.Role) {}

    func syncRecords() -> [SyncRecord] { held.records }

    @discardableResult
    func applySync(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        guard !isWaitingForFiles else { return false }
        var next = held
        guard next.apply(saves: saves, deletes: deletes, known: known) else { return true }
        let previous = held
        held = next
        if save() { return true }
        held = previous
        return false
    }

    /// Hands items to a store that understands them now. One stays held until that store has
    /// saved it. An item the store already has is newer, so the held copy is just let go.
    func release(to sources: [SyncSource]) {
        guard !isWaitingForFiles else { return }
        for source in sources where source !== self && !source.isWaitingForFiles {
            let records = held.records(in: source.collections)
            guard !records.isEmpty else { continue }
            let present = Set(source.syncRecords().map(\.key))
            let missing = records.filter { !present.contains($0.key) }
            guard missing.isEmpty || source.applySync(saves: missing, deletes: []) else { continue }
            held.remove(records.map(\.key))
            save()
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !isWaitingForFiles else { return false }
        // Nothing held and no file: don't create one.
        if held.isEmpty && !FileManager.default.fileExists(atPath: storage.folder.appendingPathComponent(Self.file).path) { return true }
        return storage.save(held.records, Self.file)
    }
}
