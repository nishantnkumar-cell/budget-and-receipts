import Foundation

public struct SubscriptionTracker: Sendable {
    public let schedule = SubscriptionSchedule()

    public init() {}

    public func matches(transaction: BankTransaction, contract: SubscriptionContract) -> Bool {
        let source = "\(transaction.merchant) \(transaction.description)".lowercased()
        let terms = ([contract.vendor] + contract.transactionMatchers).map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return terms.contains { source.contains($0) }
    }

    public func payments(for contract: SubscriptionContract, transactions: [BankTransaction]) -> [SubscriptionPayment] {
        transactions.filter { matches(transaction: $0, contract: contract) && $0.amount < 0 }.map {
            SubscriptionPayment(subscriptionID: contract.id, transactionID: $0.id, vendor: contract.vendor, date: $0.date, amount: abs($0.amount))
        }.sorted { $0.date < $1.date }
    }

    public func vendorSummary(contract: SubscriptionContract, transactions: [BankTransaction]) -> VendorSpendSummary {
        let values = payments(for: contract, transactions: transactions)
        let total = values.reduce(Decimal(0)) { $0 + $1.amount }
        return VendorSpendSummary(vendor: contract.vendor, totalPaid: total, paymentCount: values.count, firstPayment: values.first?.date, lastPayment: values.last?.date, averagePayment: values.isEmpty ? 0 : total / Decimal(values.count))
    }

    public func dueSoon(_ contracts: [SubscriptionContract], from date: Date, days: Int = 30) -> [SubscriptionContract] {
        let end = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        return contracts.filter { $0.status == .active && $0.nextPaymentDueDate >= date && $0.nextPaymentDueDate <= end }.sorted { $0.nextPaymentDueDate < $1.nextPaymentDueDate }
    }

    public func renewalSoon(_ contracts: [SubscriptionContract], from date: Date, days: Int = 60) -> [SubscriptionContract] {
        let end = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
        return contracts.filter { contract in
            guard contract.status == .active, let renewal = contract.renewalDate else { return false }
            return renewal >= date && renewal <= end
        }.sorted { ($0.renewalDate ?? .distantFuture) < ($1.renewalDate ?? .distantFuture) }
    }
}
