import BudgetCore
import Foundation

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published var contracts: [SubscriptionContract] = []
    private let storage: JSONFileStorage

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
    }
}
