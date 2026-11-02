import Foundation

@MainActor final class SubscriptionStore: ObservableObject {
    @Published var contracts: [SubscriptionContract] = []
    private let url: URL

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BudgetMacPersonal", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("subscriptions.json")
        load()
    }

    func save(_ contract: SubscriptionContract) {
        if let index = contracts.firstIndex(where: { $0.id == contract.id }) { contracts[index] = contract }
        else { contracts.append(contract) }
        persist()
    }

    func delete(_ contract: SubscriptionContract) { contracts.removeAll { $0.id == contract.id }; persist() }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        contracts = (try? JSONDecoder().decode([SubscriptionContract].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(contracts) { try? data.write(to: url, options: .atomic) }
    }
}
