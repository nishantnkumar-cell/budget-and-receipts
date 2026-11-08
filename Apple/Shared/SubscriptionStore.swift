import BudgetCore
import Foundation

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published var contracts: [SubscriptionContract] = []
    private let storage: JSONFileStorage
    private(set) var unreadableFiles: [String] = []
    /// True while the file is locked away (see `BudgetStore.isWaitingForFiles`).
    private(set) var isWaitingForFiles = false
    /// Called after every local change is saved, so iCloud sync can send it.
    var didPersist: (() -> Void)?

    init(folder: URL = JSONFileStorage.defaultFolder) {
        storage = JSONFileStorage(folder: folder)
        load()
        removeUnsavedFiles()
    }

    private func load() {
        isWaitingForFiles = false
        do {
            contracts = try storage.loadChecked("subscriptions.json") ?? []
        } catch JSONFileStorage.LoadError.locked {
            isWaitingForFiles = true
        } catch {
            storage.setAside("subscriptions.json")
            unreadableFiles = ["subscriptions.json"]
        }
    }

    @discardableResult
    func reloadIfWaiting() -> Bool {
        guard isWaitingForFiles else { return true }
        load()
        return !isWaitingForFiles
    }

    func save(_ contract: SubscriptionContract) {
        if let index = contracts.firstIndex(where: { $0.id == contract.id }) {
            contracts[index] = contract
        } else {
            contracts.append(contract)
        }
        persist()
    }

    /// Subscriptions and bills whose latest payment costs more than before, by contract.
    func priceRises(transactions: [BankTransaction]) -> [UUID: PriceRise] {
        Dictionary(SubscriptionTracker().priceRises(contracts, transactions: transactions).map { ($0.contractID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func resetAllData() {
        contracts = []
        persist()
    }

    func delete(_ contract: SubscriptionContract) {
        contracts.removeAll { $0.id == contract.id }
        removeFiles(contract.documents ?? [])
        persist()
    }

    var documentFiles: ContractDocumentStore { ContractDocumentStore(dataFolder: storage.folder) }

    /// Deletes stored document files, unless another contract still uses them.
    func removeFiles(_ documents: [ContractDocument]) {
        let inUse = Set(contracts.flatMap { $0.documents ?? [] }.map(\.fileName))
        for document in documents where !inUse.contains(document.fileName) { documentFiles.remove(document) }
    }

    /// Document files added in an editor that wasn't saved yet. Kept on disk until the next
    /// launch, then deleted if no contract uses them (the editor was left without saving).
    private static let unsavedFile = "contract-files-unsaved.json"

    func noteUnsaved(_ document: ContractDocument) {
        var names: [String] = storage.load(Self.unsavedFile) ?? []
        names.append(document.fileName)
        storage.save(names, Self.unsavedFile)
    }

    private func removeUnsavedFiles() {
        guard !isWaitingForFiles, let names: [String] = storage.load(Self.unsavedFile), !names.isEmpty else { return }
        removeFiles(names.map { ContractDocument(fileName: $0, title: "") })
        storage.save([String](), Self.unsavedFile)
    }

    /// Contracts that need looking at now: ending, renewing or near the last day to give notice.
    func needingAttention(now: Date = Date()) -> [ContractAttention] {
        ContractWatch().needingAttention(contracts, now: now)
    }

    private func persist() {
        guard !isWaitingForFiles else { return }
        storage.save(contracts, "subscriptions.json")
        didPersist?()
    }
}

extension SubscriptionStore: SyncSource {
    func syncRecords() -> [SyncRecord] {
        SyncRecord.records(contracts, collection: "contracts", id: \.id.uuidString, isPrivate: { $0.isPrivate == true })
            + documentRecords()
    }

    /// Contract documents travel as files, private when their contract is. A PDF too big for an
    /// iCloud record stays on this device.
    private func documentRecords() -> [SyncRecord] {
        let files = documentFiles
        var used: [String: Bool] = [:]
        for contract in contracts {
            for document in contract.documents ?? [] where files.url(for: document) != nil && files.syncs(document) {
                used[document.fileName] = (used[document.fileName] ?? true) && contract.isPrivate == true
            }
        }
        return used.map { SyncRecord(collection: "contractFiles", id: $0.key, payload: Data(), isPrivate: $0.value, fileName: $0.key) }
    }

    @discardableResult
    func applySync(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        contracts = SyncMerge.apply(saves: saves, deletes: deletes, to: contracts, collection: "contracts", id: \.id.uuidString)
        return storage.save(contracts, "subscriptions.json")
    }
}
