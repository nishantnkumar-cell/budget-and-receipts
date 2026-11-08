import Foundation

// Two more reports for the Reports area: who the spending belonged to (mine, partner's or
// shared), and net worth over time with pensions and property shown on their own lines.

/// Spending split by whose money it was: mine, the partner's, or shared.
public struct OwnerSpending: Hashable, Sendable {
    public var mine: Decimal = 0
    public var partner: Decimal = 0
    public var shared: Decimal = 0

    public init(mine: Decimal = 0, partner: Decimal = 0, shared: Decimal = 0) {
        self.mine = mine
        self.partner = partner
        self.shared = shared
    }

    public var total: Decimal { mine + partner + shared }

    public subscript(owner: MoneyOwner) -> Decimal {
        get {
            switch owner {
            case .mine: mine
            case .partner: partner
            case .shared: shared
            }
        }
        set {
            switch owner {
            case .mine: mine = newValue
            case .partner: partner = newValue
            case .shared: shared = newValue
            }
        }
    }

    /// The share of the total, from 0 to 1 (0 when nothing was spent).
    public func fraction(_ owner: MoneyOwner) -> Double {
        guard total > 0 else { return 0 }
        return NSDecimalNumber(decimal: self[owner] / total).doubleValue
    }

    /// Spending between two dates, by owner. Pass the whole household's transactions (the
    /// Together view), not ones already scaled to one person. A receipt split with its own
    /// owner counts for that owner; refunds reduce the owner's total; transfers are left out.
    public static func make(_ transactions: [BankTransaction], from: Date, to: Date, ledger: CoupleLedger,
                            calculator: BudgetCalculator = BudgetCalculator()) -> OwnerSpending {
        var result = OwnerSpending()
        for transaction in transactions where transaction.date >= from && transaction.date <= to {
            let allocations = calculator.allocations(of: transaction)
            guard !allocations.isEmpty else { continue }
            let whole = ledger.owner(of: transaction)
            if transaction.splits.isEmpty {
                result[whole] += allocations.reduce(0) { $0 + $1.1 }
            } else {
                for (split, allocation) in zip(transaction.splits, allocations) {
                    result[split.owner ?? whole] += allocation.1
                }
            }
        }
        return result
    }
}

/// Net worth at the end of one month, by report group (debts negative).
public struct NetWorthPoint: Identifiable, Hashable, Sendable {
    public var id: Date { month }
    public let month: Date
    public let groups: [WealthAccount.Group: Decimal]

    public var total: Decimal { groups.values.reduce(0, +) }
    public func amount(_ group: WealthAccount.Group) -> Decimal { groups[group] ?? 0 }
}

/// Net worth over a run of months. Pensions and property are kept apart from everything
/// else, because neither can be spent: the report shows what's left without them.
public struct NetWorthReport: Hashable, Sendable {
    /// Oldest first. Months before the first value was entered are left out.
    public let points: [NetWorthPoint]
    /// Today's figures, by group.
    public let current: NetWorthPoint

    public var total: Decimal { current.total }
    public var pensions: Decimal { current.amount(.pensions) }
    /// What the property is worth, before the mortgage.
    public var property: Decimal { current.amount(.property) }
    /// The amount owed on mortgages, as a negative number.
    public var mortgage: Decimal { current.amount(.mortgage) }
    /// Property less the mortgages: the share of the home that's owned.
    public var homeEquity: Decimal { property + mortgage }
    /// Net worth without pensions, property and the mortgages on it: cash, investments and
    /// other debts, the money that can actually be reached.
    public var excludingPensionsAndProperty: Decimal { total - pensions - homeEquity }
    /// The change since the first month of the report, or nil with only one month.
    public var change: Decimal? {
        guard points.count > 1, let first = points.first else { return nil }
        return total - first.total
    }

    /// The groups with any accounts, in report order, with today's amounts.
    public var groups: [(group: WealthAccount.Group, amount: Decimal)] {
        WealthAccount.Group.allCases.compactMap { group in current.groups[group].map { (group, $0) } }
    }

    public static func == (lhs: NetWorthReport, rhs: NetWorthReport) -> Bool {
        lhs.points == rhs.points && lhs.current == rhs.current
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(points)
        hasher.combine(current)
    }

    /// The report for one side of the household. With no ledger (no partner yet) every
    /// account counts in full; with one, shared accounts count by each person's share.
    public static func make(_ accounts: [WealthAccount], view: HouseholdView = .together, ledger: CoupleLedger? = nil,
                            months: Int = 12, now: Date = Date(), calendar: Calendar = .current) -> NetWorthReport {
        func point(_ month: Date, on date: Date) -> NetWorthPoint {
            var groups: [WealthAccount.Group: Decimal] = [:]
            for account in accounts {
                let share = ledger?.share(of: account.owner ?? .mine, for: view) ?? 1
                guard share != 0 else { continue }
                groups[account.kind.group, default: 0] += account.contribution(on: date) * share
            }
            return NetWorthPoint(month: month, groups: groups)
        }
        let current = point(calendar.dateInterval(of: .month, for: now)?.start ?? now, on: now)
        guard let first = accounts.flatMap(\.balances).map(\.date).min() else {
            return NetWorthReport(points: [], current: current)
        }
        let points = (0..<max(months, 1)).reversed().compactMap { back -> NetWorthPoint? in
            guard let month = calendar.date(byAdding: .month, value: -back, to: now),
                  let interval = calendar.dateInterval(of: .month, for: month) else { return nil }
            let end = min(interval.end.addingTimeInterval(-1), now)
            guard end >= first else { return nil }
            return point(interval.start, on: end)
        }
        return NetWorthReport(points: points, current: current)
    }
}

public extension NetWorthReport {
    /// One row per month, one column per group, then the total and the total without
    /// pensions and property.
    func csv(calendar: Calendar = .current) -> String {
        let groups = WealthAccount.Group.allCases.filter { current.groups[$0] != nil }
        var text = "Month," + groups.map { CSVExporter.escape($0.title) }.joined(separator: ",") + ",Net worth,Without pensions and property\r\n"
        for point in points {
            let parts = calendar.dateComponents([.year, .month], from: point.month)
            let pensions = point.amount(.pensions)
            let home = point.amount(.property) + point.amount(.mortgage)
            text += String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0) + ","
                + groups.map { "\(point.amount($0))" }.joined(separator: ",")
                + ",\(point.total),\(point.total - pensions - home)\r\n"
        }
        return text
    }
}
