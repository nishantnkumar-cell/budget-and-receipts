import BudgetCore
import Foundation

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published var contracts: [SubscriptionContract] = []
    private let storage: JSONFileStorage
    /// Called after every local change is saved, so iCloud sync can send it.
    var didPersist: (() -> Void)?

    init(folder: URL = JSONFileStorage.defaultFolder) {
        storage = JSONFileStorage(folder: folder)
        contracts = storage.load("subscriptions.json") ?? []
    }

    func save(_ contract: SubscriptionContract) {
        if let index = contracts.firstIndex(where: { $0.id == contract.id }) {
            contracts[index] = contract
        } else {
            contracts.append(contract)
        }
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

    func applySync(saves: [SyncRecord], deletes: Set<String>) {
        contracts = SyncMerge.apply(saves: saves, deletes: deletes, to: contracts, collection: "contracts", id: \.id.uuidString)
        storage.save(contracts, "subscriptions.json")
    }
}
