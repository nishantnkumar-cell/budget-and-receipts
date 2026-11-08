import Foundation

/// A file kept with a contract: the signed agreement, a contract summary, a photo of the paperwork.
/// The file itself lives next to the app's data (and in end-to-end encrypted iCloud), named by
/// `fileName`; this is only the label and where to find it.
public struct ContractDocument: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// The stored file's name, "<UUID>.pdf" or "<UUID>.jpg".
    public var fileName: String
    /// What the person calls it, e.g. "Signed contract".
    public var title: String
    public var added: Date

    public init(id: UUID = UUID(), fileName: String, title: String, added: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.added = added
    }

    public var isPDF: Bool { fileName.lowercased().hasSuffix(".pdf") }
}

/// How much a contract needs looking at right now.
public enum ContractUrgency: Hashable, Sendable {
    /// The term (or renewal) date has passed: it may have rolled onto a pricier deal.
    case ended(Date)
    /// The last day to give notice is close.
    case giveNoticeBy(Date, days: Int)
    /// Too late to give notice before it ends or renews.
    case noticeMissed(ends: Date, days: Int)
    /// Ends or renews soon.
    case endingSoon(Date, days: Int)

    /// Lower sorts first: the thing to act on today.
    public var rank: Int {
        switch self {
        case .giveNoticeBy: 0
        case .ended: 1
        case .noticeMissed: 2
        case .endingSoon: 3
        }
    }

    /// The date it's about.
    public var date: Date {
        switch self {
        case .ended(let date), .giveNoticeBy(let date, _), .noticeMissed(let date, _), .endingSoon(let date, _): date
        }
    }

    /// Red-flag cases: the notice deadline is near, or the term has run out.
    public var isUrgent: Bool {
        switch self {
        case .giveNoticeBy, .ended: true
        case .noticeMissed, .endingSoon: false
        }
    }
}

public struct ContractAttention: Identifiable, Hashable, Sendable {
    public var id: UUID { contract.id }
    public let contract: SubscriptionContract
    public let urgency: ContractUrgency
}

/// Spots fixed-term contracts that are ending, renewing or past their notice date.
public struct ContractWatch: Sendable {
    public var calendar: Calendar
    /// Flag a contract this many days before it ends or renews.
    public var endingDays: Int
    /// Flag the last day to give notice this many days ahead.
    public var noticeDays: Int
    /// Keep flagging an ended contract for this long, then let it go quiet.
    public var endedDays: Int

    public init(calendar: Calendar = .current, endingDays: Int = 60, noticeDays: Int = 30, endedDays: Int = 120) {
        self.calendar = calendar
        self.endingDays = endingDays
        self.noticeDays = noticeDays
        self.endedDays = endedDays
    }

    /// When an active contract ends or renews: the renewal if it has one, else its term's end.
    public static func endDate(_ contract: SubscriptionContract) -> Date? {
        contract.renewalDate ?? contract.minimumTermEndDate
    }

    /// The last day to give notice, when the contract has a notice period.
    public func noticeDeadline(_ contract: SubscriptionContract) -> Date? {
        guard let end = Self.endDate(contract), let notice = contract.cancellationNoticeDays, notice > 0 else { return nil }
        return calendar.date(byAdding: .day, value: -notice, to: end)
    }

    public func urgency(_ contract: SubscriptionContract, now: Date) -> ContractUrgency? {
        guard contract.status == .active, contract.isContract, let end = Self.endDate(contract) else { return nil }
        let today = calendar.startOfDay(for: now)
        let daysToEnd = days(from: today, to: end)
        if daysToEnd < 0 {
            return -daysToEnd <= endedDays ? .ended(end) : nil
        }
        if let deadline = noticeDeadline(contract) {
            let daysToDeadline = days(from: today, to: deadline)
            if daysToDeadline >= 0 {
                if daysToDeadline <= noticeDays { return .giveNoticeBy(deadline, days: daysToDeadline) }
            } else {
                return .noticeMissed(ends: end, days: daysToEnd)
            }
        }
        return daysToEnd <= endingDays ? .endingSoon(end, days: daysToEnd) : nil
    }

    /// Contracts worth looking at now, the most pressing first.
    public func needingAttention(_ contracts: [SubscriptionContract], now: Date) -> [ContractAttention] {
        contracts.compactMap { contract in urgency(contract, now: now).map { ContractAttention(contract: contract, urgency: $0) } }
            .sorted { ($0.urgency.rank, $0.urgency.date, $0.contract.vendor) < ($1.urgency.rank, $1.urgency.date, $1.contract.vendor) }
    }

    private func days(from today: Date, to date: Date) -> Int {
        calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
    }
}
