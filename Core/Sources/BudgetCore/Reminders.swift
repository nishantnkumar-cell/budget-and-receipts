import Foundation

public enum ReminderKind: String, Codable, CaseIterable, Sendable {
    case paymentDue
    case cancellationDeadline
    case renewal
    case fixedPriceEnds
    /// A fixed term ending without a set renewal date.
    case contractEnds
}

/// A reminder the app should show as a local notification.
public struct ContractReminder: Hashable, Sendable {
    public let contractID: UUID
    public let kind: ReminderKind
    /// When to notify.
    public let fireDate: Date
    /// The date the reminder is about (the payment, renewal or deadline).
    public let eventDate: Date
    public let title: String
    public let body: String

    /// Stable id, so rescheduling replaces a reminder instead of duplicating it.
    public var identifier: String { "\(contractID.uuidString).\(kind.rawValue)" }
}

/// Works out which reminders each active contract needs. Foundation-only, so every app agrees.
public struct ReminderPlanner: Sendable {
    public var calendar: Calendar
    /// Days before a payment to remind.
    public var paymentLeadDays = 2
    /// Days before a renewal or a fixed price ending to remind.
    public var renewalLeadDays = 14
    /// Days before a fixed term ends to remind, so there's time to compare deals.
    public var contractEndLeadDays = 30
    /// Hour of the day to notify, in the calendar's time zone.
    public var hour = 9

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func reminders(for contracts: [SubscriptionContract], now: Date) -> [ContractReminder] {
        contracts.filter { $0.status == .active }.flatMap { reminders(for: $0, now: now) }.sorted { $0.fireDate < $1.fireDate }
    }

    public func reminders(for contract: SubscriptionContract, now: Date) -> [ContractReminder] {
        var result: [ContractReminder] = []
        let amount = contract.expectedAmount.formatted(.currency(code: contract.currency))

        func add(_ kind: ReminderKind, event: Date, leadDays: Int, title: String, body: String) {
            guard let fire = fireDate(daysBefore: leadDays, event), fire > now else { return }
            result.append(ContractReminder(contractID: contract.id, kind: kind, fireDate: fire, eventDate: event, title: title, body: body))
        }

        let paymentLead = contract.remindDaysBefore ?? paymentLeadDays
        if paymentLead > 0 {
            add(.paymentDue, event: contract.nextPaymentDueDate, leadDays: paymentLead,
                title: "\(contract.vendor) payment due", body: "\(amount) is due on \(dayText(contract.nextPaymentDueDate)).")
        }

        // Notice is given before the contract renews, or before its term ends (as Home shows).
        if let deadline = ContractWatch(calendar: calendar).noticeDeadline(contract) {
            add(.cancellationDeadline, event: deadline, leadDays: 7,
                title: "Decide on \(contract.vendor)", body: "To cancel or switch before it \(contract.renewalDate == nil ? "ends" : "renews"), give notice by \(dayText(deadline)).")
        }
        if let renewal = contract.renewalDate {
            add(.renewal, event: renewal, leadDays: renewalLeadDays,
                title: "\(contract.vendor) renews soon", body: "It renews on \(dayText(renewal)). Check the price before then.")
        } else if contract.isContract, let ends = contract.minimumTermEndDate {
            add(.contractEnds, event: ends, leadDays: contractEndLeadDays,
                title: "\(contract.vendor) contract ends soon", body: "The term ends on \(dayText(ends)). Look for a better deal before then.")
        }

        if let fixedEnd = contract.fixedPriceEndDate, contract.pricing == .fixed || contract.pricing == .introductory {
            add(.fixedPriceEnds, event: fixedEnd, leadDays: renewalLeadDays,
                title: "\(contract.vendor) price may rise", body: "The fixed price ends on \(dayText(fixedEnd)).")
        }
        return result
    }

    private func fireDate(daysBefore days: Int, _ event: Date) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: event)) else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    private func dayText(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.wide).year()
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
