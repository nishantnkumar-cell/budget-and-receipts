import Foundation

/// Something on its way: a recurring payment, or a date in a contract worth acting on.
public struct UpcomingItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case payment
        /// The last day to give notice before a contract renews.
        case cancellationDeadline
        case renewal
        case fixedPriceEnds
        case minimumTermEnds

        /// On the same day, the thing to act on comes first.
        var order: Int {
            switch self {
            case .cancellationDeadline: 0
            case .payment: 1
            case .minimumTermEnds: 2
            case .fixedPriceEnds: 3
            case .renewal: 4
            }
        }
    }

    public var id: String { "\(contractID)|\(kind.rawValue)|\(date.timeIntervalSinceReferenceDate)" }
    public let contractID: UUID
    public let vendor: String
    public let kind: Kind
    public let date: Date
    /// The payment amount; nil for contract dates.
    public let amount: Decimal?
    public let currency: String
    public let billingPeriod: BillingPeriod

    public init(contractID: UUID, vendor: String, kind: Kind, date: Date, amount: Decimal?, currency: String, billingPeriod: BillingPeriod) {
        self.contractID = contractID
        self.vendor = vendor
        self.kind = kind
        self.date = date
        self.amount = amount
        self.currency = currency
        self.billingPeriod = billingPeriod
    }
}

/// What Home's "Coming up" shows: the next recurring payments, and contract renewals and
/// deadlines further ahead, because those need deciding before the day.
public struct ComingUpPlanner: Sendable {
    public var calendar: Calendar
    /// How far ahead to list payments.
    public var paymentDays: Int
    /// How far ahead to list renewals and other contract dates.
    public var contractDays: Int

    public init(calendar: Calendar = .current, paymentDays: Int = 30, contractDays: Int = 90) {
        self.calendar = calendar
        self.paymentDays = paymentDays
        self.contractDays = contractDays
    }

    /// Each active contract's payments due in the window, soonest first. A due date already
    /// in the past (not yet marked paid) is rolled forward to the next one, so a stale entry
    /// never hides the payment that is really next. Weekly bills appear once per week.
    public func payments(_ contracts: [SubscriptionContract], from now: Date) -> [UpcomingItem] {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: paymentDays, to: start) else { return [] }
        let schedule = SubscriptionSchedule(calendar: calendar)
        var items: [UpcomingItem] = []
        for contract in contracts where contract.status == .active {
            var due = contract.nextPaymentDueDate
            var guardCount = 0
            while calendar.startOfDay(for: due) < start, guardCount < 500,
                  let next = schedule.nextDate(after: due, period: contract.billingPeriod, customIntervalDays: contract.customIntervalDays) {
                due = next
                guardCount += 1
            }
            while due < end, guardCount < 500 {
                if calendar.startOfDay(for: due) >= start {
                    items.append(item(contract, .payment, due, amount: contract.expectedAmount))
                }
                guard let next = schedule.nextDate(after: due, period: contract.billingPeriod, customIntervalDays: contract.customIntervalDays) else { break }
                due = next
                guardCount += 1
            }
        }
        return items.sorted { ($0.date, $0.vendor) < ($1.date, $1.vendor) }
    }

    /// Contract dates: renewals, notice deadlines, fixed prices ending and terms ending, soonest
    /// first. Only fixed-term contracts have these; subscriptions only have payments.
    public func contractDates(_ contracts: [SubscriptionContract], from now: Date) -> [UpcomingItem] {
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: contractDays, to: start) else { return [] }
        var items: [UpcomingItem] = []
        for contract in contracts where contract.status == .active && contract.isContract {
            func add(_ kind: UpcomingItem.Kind, _ date: Date?) {
                guard let date, calendar.startOfDay(for: date) >= start, date < end else { return }
                items.append(item(contract, kind, date, amount: nil))
            }
            // Notice is given before the contract renews, or before its term ends.
            if let ends = contract.renewalDate ?? contract.minimumTermEndDate,
               let notice = contract.cancellationNoticeDays, notice > 0 {
                add(.cancellationDeadline, calendar.date(byAdding: .day, value: -notice, to: ends))
            }
            if let renewal = contract.renewalDate {
                add(.renewal, renewal)
            }
            if contract.pricing == .fixed || contract.pricing == .introductory {
                add(.fixedPriceEnds, contract.fixedPriceEndDate)
            }
            if contract.minimumTermEndDate != contract.renewalDate {
                add(.minimumTermEnds, contract.minimumTermEndDate)
            }
        }
        return items.sorted { ($0.date, $0.vendor, $0.kind.order) < ($1.date, $1.vendor, $1.kind.order) }
    }

    /// Total of the payments in the window, per currency.
    public func totalDue(_ payments: [UpcomingItem]) -> [String: Decimal] {
        payments.reduce(into: [:]) { $0[$1.currency, default: 0] += $1.amount ?? 0 }
    }

    private func item(_ contract: SubscriptionContract, _ kind: UpcomingItem.Kind, _ date: Date, amount: Decimal?) -> UpcomingItem {
        UpcomingItem(contractID: contract.id, vendor: contract.vendor, kind: kind, date: date, amount: amount, currency: contract.currency, billingPeriod: contract.billingPeriod)
    }
}
