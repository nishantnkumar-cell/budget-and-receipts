#if DEBUG
import BudgetCore
import Foundation

/// Made-up data for screenshots and design checks: launch a Debug build with `-SampleData`.
/// It lives in a temporary folder, so your own data is never touched, and sync stays off.
enum SampleData {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-SampleData") }

    private static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DuoBudgetSample-\(UUID().uuidString)", isDirectory: true)

    @MainActor static func budgetStore() -> BudgetStore {
        let store = BudgetStore(folder: folder)
        let joint = store.addAccount(name: "HSBC joint")
        let amex = store.addAccount(name: "Amex")
        var firstDirect = store.addAccount(name: "first direct")
        firstDirect.owner = .partner
        store.updateAccount(firstDirect)
        store.updateCouple(CoupleSettings(partnerName: "Priya"))
        let calendar = Calendar.current
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date() }
        let rows: [(Int, String, Decimal, String, UUID, MoneyOwner?)] = [
            (0, "Tesco Extra", -64.20, "Groceries", joint.id, .shared),
            (0, "Netflix", -10.99, "Subscriptions", amex.id, .mine),
            (1, "Zara", -45.00, "Shopping", firstDirect.id, nil),
            (1, "Pret A Manger", -8.40, "Eating out", amex.id, nil),
            (2, "Octopus Energy", -92.00, "Bills & utilities", joint.id, .shared),
            (3, "Salary", 2850.00, "Income", joint.id, .mine),
            (4, "Uber", -14.60, "Transport", firstDirect.id, nil),
            (5, "Waitrose", -38.75, "Groceries", joint.id, .shared),
            (6, "Boots", -12.30, "Health", firstDirect.id, nil),
            (7, "Dishoom", -71.40, "Eating out", joint.id, .shared),
            (8, "Spotify", -12.99, "Subscriptions", joint.id, .shared),
            (38, "Spotify", -10.99, "Subscriptions", joint.id, .shared),
            (35, "Sainsbury's", -82.10, "Groceries", joint.id, .shared),
            (33, "Amazon", -23.99, "Shopping", amex.id, .mine),
            (30, "Octopus Energy", -92.00, "Bills & utilities", joint.id, .shared),
            (28, "Deliveroo", -24.80, "Eating out", joint.id, .shared),
            (25, "TfL", -46.80, "Transport", amex.id, .mine),
            (21, "IKEA", -86.50, "Shopping", joint.id, .shared),
            (16, "Waitrose", -54.25, "Groceries", joint.id, .shared)
        ]
        for (index, row) in rows.enumerated() {
            var transaction = BankTransaction(date: day(row.0), merchant: row.1, amount: row.2, category: row.3,
                                              fingerprint: "sample-\(index)", owner: row.5)
            transaction.accountID = row.4
            store.add(transaction)
        }
        store.setBudget(category: "Groceries", limit: 400)
        store.setBudget(category: "Eating out", limit: 200)
        store.setBudget(category: "Shopping", limit: 200)
        store.setBudget(category: "Transport", limit: 140)
        return store
    }

    @MainActor static func subscriptionStore() -> SubscriptionStore {
        let store = SubscriptionStore(folder: folder)
        let calendar = Calendar.current
        func ahead(_ days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: Date()) ?? Date() }
        let bills: [(String, SubscriptionCategory, Int, Decimal)] = [
            ("Spotify", .other, 3, 12.99), ("EE mobile", .other, 5, 18.00), ("Thames Water", .other, 6, 41.00), ("Council tax", .other, 12, 164.00)
        ]
        for bill in bills {
            store.save(SubscriptionContract(vendor: bill.0, category: bill.1, startDate: ahead(-400), billingPeriod: .monthly,
                                            nextPaymentDueDate: ahead(bill.2), expectedAmount: bill.3, currency: AppSettings.currency))
        }
        return store
    }
}
#endif
