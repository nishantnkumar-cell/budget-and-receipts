import Foundation

public struct SubscriptionSchedule: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public func nextDate(after date: Date, period: BillingPeriod, customIntervalDays: Int? = nil) -> Date? {
        switch period {
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly: return calendar.date(byAdding: .month, value: 3, to: date)
        case .halfYearly: return calendar.date(byAdding: .month, value: 6, to: date)
        case .yearly: return calendar.date(byAdding: .year, value: 1, to: date)
        case .custom:
            guard let days = customIntervalDays, days > 0 else { return nil }
            return calendar.date(byAdding: .day, value: days, to: date)
        }
    }

    public func advanceDueDate(_ contract: SubscriptionContract, after paymentDate: Date) -> Date {
        var due = contract.nextPaymentDueDate
        while due <= paymentDate {
            guard let next = nextDate(after: due, period: contract.billingPeriod, customIntervalDays: contract.customIntervalDays) else { break }
            due = next
        }
        return due
    }

    public func annualisedCost(_ contract: SubscriptionContract) -> Decimal {
        switch contract.billingPeriod {
        case .weekly: return contract.expectedAmount * 52
        case .monthly: return contract.expectedAmount * 12
        case .quarterly: return contract.expectedAmount * 4
        case .halfYearly: return contract.expectedAmount * 2
        case .yearly: return contract.expectedAmount
        case .custom:
            guard let days = contract.customIntervalDays, days > 0 else { return 0 }
            return contract.expectedAmount * Decimal(365) / Decimal(days)
        }
    }
}
