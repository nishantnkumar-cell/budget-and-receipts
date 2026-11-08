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
        func months(_ n: Int) -> Date { calendar.date(byAdding: .month, value: -n, to: Date()) ?? Date() }
        // A year of everyday history, so Reports has trends to show.
        let history: [(String, Decimal, String, String?, UUID, MoneyOwner?, Int)] = [
            ("Salary", 2850, "Income", "Salary", joint.id, .mine, 1),
            ("Priya salary", 2400, "Income", "Salary", firstDirect.id, .partner, 1),
            ("Tesco Extra", -88.40, "Groceries", "Supermarket", joint.id, .shared, 3),
            ("Waitrose", -46.10, "Groceries", "Supermarket", joint.id, .shared, 9),
            ("Tesco Extra", -71.25, "Groceries", "Supermarket", joint.id, .shared, 17),
            ("Octopus Energy", -92, "Bills & utilities", "Energy", joint.id, .shared, 2),
            ("Thames Water", -38.50, "Bills & utilities", "Water", joint.id, .shared, 5),
            ("Pret A Manger", -7.80, "Eating out", "Coffee", amex.id, .mine, 6),
            ("Dishoom", -64.00, "Eating out", "Restaurant", joint.id, .shared, 13),
            ("Deliveroo", -27.40, "Eating out", "Takeaway", joint.id, .shared, 20),
            ("TfL", -42.60, "Transport", "Public transport", amex.id, .mine, 11),
            ("Shell", -58.00, "Transport", "Fuel", firstDirect.id, .partner, 15),
            ("Amazon", -31.99, "Shopping", "Online marketplace", amex.id, .mine, 19),
            ("Netflix", -10.99, "Subscriptions", "Streaming", amex.id, .mine, 8),
            ("Spotify", -12.99, "Subscriptions", "Music", joint.id, .shared, 8),
            ("PureGym", -24.99, "Health", "Fitness", firstDirect.id, .partner, 4),
        ]
        var sampleIndex = 1000
        for back in 2...12 {
            let wobble = Decimal((back * 37) % 23) / 100   // up to ±23% month to month, always the same
            for row in history {
                guard let month = calendar.date(byAdding: .month, value: -back, to: Date()),
                      let date = calendar.date(bySetting: .day, value: row.6, of: month) else { continue }
                let scale: Decimal = row.2 == "Income" || row.2 == "Subscriptions" || row.3 == "Energy" ? 1 : 0.88 + wobble
                var transaction = BankTransaction(date: date, merchant: row.0, amount: row.1 * scale, category: row.2,
                                                  fingerprint: "sample-\(sampleIndex)", owner: row.5)
                transaction.subcategory = row.3
                transaction.accountID = row.4
                store.add(transaction)
                sampleIndex += 1
            }
        }
        if let summer = calendar.date(byAdding: .month, value: -4, to: Date()) {
            var flights = BankTransaction(date: summer, merchant: "British Airways", amount: -684, category: "Travel", fingerprint: "sample-flights", owner: .shared)
            flights.subcategory = "Flights"
            flights.accountID = amex.id
            store.add(flights)
        }
        let wealth: [(String, WealthAccount.Kind, MoneyOwner, [Decimal])] = [
            ("Our home", .property, .shared, [395_000, 398_000, 400_000]),
            ("Mortgage", .mortgage, .shared, [231_400, 230_200, 229_000]),
            ("Workplace pension", .pension, .mine, [46_100, 47_300, 48_200]),
            ("Priya's pension", .pension, .partner, [31_800, 32_400]),
            ("Stocks and shares ISA", .investment, .mine, [20_400, 21_100, 22_000]),
            ("Easy access savings", .savings, .shared, [8_200, 8_600, 9_000]),
            ("HSBC joint current", .cash, .shared, [2_900, 3_150, 3_412])
        ]
        var homeID: UUID?
        for item in wealth {
            var account = WealthAccount(name: item.0, kind: item.1, owner: item.2,
                                        balances: item.3.enumerated().map { WealthAccount.Balance(date: months(item.3.count - 1 - $0.offset), amount: $0.element) })
            if item.1 == .property { homeID = account.id }
            if item.1 == .mortgage {
                account.propertyID = homeID
                account.repayment = WealthAccount.Repayment(annualRate: 0.0449, monthlyPayment: 1_120)
            }
            if item.0 == "Priya's pension" { account.balances = account.balances.map { .init(date: calendar.date(byAdding: .month, value: -2, to: $0.date) ?? $0.date, amount: $0.amount) } }
            store.saveWealthAccount(account)
        }
        if let tesco = store.transactions.first(where: { $0.merchant == "Tesco Extra" }) {
            store.addNote(to: tesco, text: "Includes the party food for Saturday")
            store.addNote(to: tesco, reaction: "👍")
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
            ("Spotify", .streaming, 3, 12.99), ("Thames Water", .utilities, 6, 41.00), ("Council tax", .other, 12, 164.00)
        ]
        for bill in bills {
            store.save(SubscriptionContract(vendor: bill.0, category: bill.1, startDate: ahead(-400), billingPeriod: .monthly,
                                            nextPaymentDueDate: ahead(bill.2), expectedAmount: bill.3, currency: AppSettings.currency))
        }
        store.save(SubscriptionContract(vendor: "Car insurance", category: .insurance, startDate: ahead(-300), billingPeriod: .yearly,
                                        nextPaymentDueDate: ahead(150), expectedAmount: 540, currency: AppSettings.currency))
        store.save(SubscriptionContract(vendor: "Amazon Prime", category: .membership, startDate: ahead(-200), billingPeriod: .yearly,
                                        nextPaymentDueDate: ahead(90), expectedAmount: 95, currency: AppSettings.currency))
        var phone = SubscriptionContract(vendor: "EE mobile", category: .mobile, startDate: ahead(-670), billingPeriod: .monthly,
                                         nextPaymentDueDate: ahead(5), expectedAmount: 18, currency: AppSettings.currency, pricing: .fixed,
                                         cancellationNoticeDays: 30, kind: .contract)
        phone.minimumTermEndDate = ahead(60)
        store.save(phone)
        var energy = SubscriptionContract(vendor: "Octopus Energy", category: .energy, startDate: ahead(-200), billingPeriod: .monthly,
                                          nextPaymentDueDate: ahead(9), expectedAmount: 96, currency: AppSettings.currency, pricing: .fixed, kind: .contract)
        energy.minimumTermEndDate = ahead(165)
        energy.fixedPriceEndDate = ahead(165)
        store.save(energy)
        return store
    }
}
#endif
