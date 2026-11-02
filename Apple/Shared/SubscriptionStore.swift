import BudgetCore
import Foundation

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published var contracts: [SubscriptionContract] = []
    private let storage: JSONFileStorage
    private(set) var unreadableFiles: [String] = []
    /// Called after every local change is saved, so iCloud sync can send it.
    var didPersist: (() -> Void)?

    init(folder: URL = JSONFileStorage.defaultFolder) {
        storage = JSONFileStorage(folder: folder)
        do {
            contracts = try storage.loadChecked("subscriptions.json") ?? []
        } catch {
            storage.setAside("subscriptions.json")
            unreadableFiles = ["subscriptions.json"]
        }
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
        persist()
    }

    private func persist() {
        storage.save(contracts, "subscriptions.json")
        didPersist?()
    }
}

extension SubscriptionStore: SyncSource {
    func syncRecords() -> [SyncRecord] {
        SyncRecord.records(contracts, collection: "contracts", id: \.id.uuidString, isPrivate: { $0.isPrivate == true })
    }

    @discardableResult
    func applySync(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        contracts = SyncMerge.apply(saves: saves, deletes: deletes, to: contracts, collection: "contracts", id: \.id.uuidString)
        return storage.save(contracts, "subscriptions.json")
    }
}
