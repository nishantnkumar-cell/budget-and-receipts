import Foundation

/// Something owned or owed that counts toward net worth. Entered by hand: there are no
/// broker or pension feeds, so it all stays on the devices and in encrypted iCloud.
public struct WealthAccount: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case cash, savings, investment, pension, property, mortgage, loan, creditCard, other

        public var isDebt: Bool { self == .mortgage || self == .loan || self == .creditCard }

        /// The report's groups: cash, investments, pensions, property, mortgage, other debts.
        public var group: Group {
            switch self {
            case .cash, .savings: .cash
            case .investment: .investments
            case .pension: .pensions
            case .property: .property
            case .mortgage: .mortgage
            case .loan, .creditCard: .otherDebts
            case .other: .other
            }
        }

        public var title: String {
            switch self {
            case .cash: "Current account"
            case .savings: "Savings"
            case .investment: "Investments"
            case .pension: "Pension"
            case .property: "Property"
            case .mortgage: "Mortgage"
            case .loan: "Loan"
            case .creditCard: "Credit card"
            case .other: "Other"
            }
        }
    }

    public enum Group: String, Codable, CaseIterable, Sendable {
        case cash, investments, pensions, property, mortgage, otherDebts, other

        public var title: String {
            switch self {
            case .cash: "Cash"
            case .investments: "Investments"
            case .pensions: "Pensions"
            case .property: "Property"
            case .mortgage: "Mortgage"
            case .otherDebts: "Other debts"
            case .other: "Other"
            }
        }
    }

    /// A value on a date. Debts are entered as the amount owed (a positive number).
    public struct Balance: Codable, Hashable, Sendable {
        public var date: Date
        public var amount: Decimal

        public init(date: Date, amount: Decimal) {
            self.date = date
            self.amount = amount
        }
    }

    /// For a mortgage or loan: what's needed to work out the payoff date.
    public struct Repayment: Codable, Hashable, Sendable {
        /// Yearly interest rate, e.g. 0.0425 for 4.25%.
        public var annualRate: Decimal
        public var monthlyPayment: Decimal

        public init(annualRate: Decimal, monthlyPayment: Decimal) {
            self.annualRate = annualRate
            self.monthlyPayment = monthlyPayment
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var owner: MoneyOwner?
    public var isPrivate: Bool?
    public var balances: [Balance]
    public var repayment: Repayment?
    /// For a mortgage: the property it's secured on, for equity.
    public var propertyID: UUID?

    public init(id: UUID = UUID(), name: String, kind: Kind, owner: MoneyOwner? = nil, balances: [Balance] = [], repayment: Repayment? = nil, propertyID: UUID? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.owner = owner
        self.balances = balances
        self.repayment = repayment
        self.propertyID = propertyID
    }

    /// The latest value on or before a date (nil when there's none yet).
    public func value(on date: Date) -> Decimal? {
        balances.filter { $0.date <= date }.max { $0.date < $1.date }?.amount
    }

    public var latest: Balance? { balances.max { $0.date < $1.date } }

    /// What it adds to net worth: assets count up, debts count down.
    public func contribution(on date: Date) -> Decimal {
        let value = value(on: date) ?? 0
        return kind.isDebt ? -value : value
    }

    /// True when the latest value is more than 30 days old (or there's none).
    public func needsUpdate(now: Date = Date()) -> Bool {
        guard let latest else { return true }
        return now.timeIntervalSince(latest.date) > 30 * 86_400
    }
}

/// Net worth from the accounts entered by hand. Pensions and property count in the total.
public struct NetWorthCalculator: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func total(_ accounts: [WealthAccount], on date: Date = Date()) -> Decimal {
        accounts.reduce(0) { $0 + $1.contribution(on: date) }
    }

    /// The Me / Partner / Together view: your accounts, plus your share of shared ones.
    public func total(_ accounts: [WealthAccount], for view: HouseholdView, ledger: CoupleLedger, on date: Date = Date()) -> Decimal {
        accounts.reduce(0) { $0 + $1.contribution(on: date) * ledger.share(of: $1.owner ?? .mine, for: view) }
    }

    /// The total in each report group (debts negative), leaving out empty groups.
    public func byGroup(_ accounts: [WealthAccount], on date: Date = Date()) -> [(group: WealthAccount.Group, amount: Decimal)] {
        WealthAccount.Group.allCases.compactMap { group in
            let members = accounts.filter { $0.kind.group == group }
            guard !members.isEmpty else { return nil }
            return (group, total(members, on: date))
        }
    }

    /// The total by owner: mine, partner, shared (an account with no owner is mine).
    public func byOwner(_ accounts: [WealthAccount], on date: Date = Date()) -> [MoneyOwner: Decimal] {
        Dictionary(grouping: accounts) { $0.owner ?? .mine }.mapValues { total($0, on: date) }
    }

    /// One net worth figure at the end of each of the last `months` months, oldest first,
    /// for the trend line. Months before any balance was entered are left out.
    public func monthlyTrend(_ accounts: [WealthAccount], months: Int = 12, now: Date = Date()) -> [(month: Date, total: Decimal)] {
        guard let first = accounts.flatMap(\.balances).map(\.date).min() else { return [] }
        return (0..<months).reversed().compactMap { back -> (Date, Decimal)? in
            guard let month = calendar.date(byAdding: .month, value: -back, to: now),
                  let interval = calendar.dateInterval(of: .month, for: month) else { return nil }
            let end = min(interval.end.addingTimeInterval(-1), now)
            guard end >= first else { return nil }
            return (interval.start, total(accounts, on: end))
        }
    }

    /// When a mortgage or loan is paid off at its current payment, or nil when the payment
    /// doesn't cover the interest.
    public func payoffDate(_ account: WealthAccount, from now: Date = Date()) -> Date? {
        guard let repayment = account.repayment, var owed = account.latest?.amount, owed > 0, repayment.monthlyPayment > 0 else { return nil }
        let monthlyRate = repayment.annualRate / 12
        var months = 0
        while owed > 0 && months < 1200 {
            let interest = owed * monthlyRate
            guard repayment.monthlyPayment > interest else { return nil }
            owed = owed + interest - repayment.monthlyPayment
            months += 1
        }
        return months < 1200 ? calendar.date(byAdding: .month, value: months, to: account.latest?.date ?? now) : nil
    }

    /// Home equity: the property's value less the mortgages secured on it.
    public func equity(of property: WealthAccount, accounts: [WealthAccount], on date: Date = Date()) -> Decimal {
        let mortgages = accounts.filter { $0.kind == .mortgage && $0.propertyID == property.id }
        return (property.value(on: date) ?? 0) - mortgages.reduce(0) { $0 + ($1.value(on: date) ?? 0) }
    }
}
