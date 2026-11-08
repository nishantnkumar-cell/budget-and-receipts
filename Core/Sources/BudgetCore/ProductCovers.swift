import Foundation

/// Something bought that can still go back to the shop, or is under warranty: a receipt's
/// return-by date and warranty end, kept with the receipt photo so you can find it later.
public struct ProductCover: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// What was bought, e.g. "Dyson V15".
    public var item: String
    public var shop: String
    public var purchased: Date
    public var price: Decimal?
    /// The last day it can be returned. Nil when there's no return window to watch.
    public var returnBy: Date?
    /// The day the warranty (or guarantee) runs out.
    public var warrantyEnds: Date?
    /// The payment it was bought with, if known.
    public var transactionID: String?
    /// The receipt photo's file name, kept with the receipt photos (and synced like them).
    public var receiptImage: String?
    public var note: String?
    /// Set once returned: it stops reminding.
    public var returned: Bool?
    public var isPrivate: Bool?

    public init(id: UUID = UUID(), item: String, shop: String, purchased: Date, price: Decimal? = nil, returnBy: Date? = nil,
                warrantyEnds: Date? = nil, transactionID: String? = nil, receiptImage: String? = nil, note: String? = nil,
                returned: Bool? = nil, isPrivate: Bool? = nil) {
        self.id = id
        self.item = item
        self.shop = shop
        self.purchased = purchased
        self.price = price
        self.returnBy = returnBy
        self.warrantyEnds = warrantyEnds
        self.transactionID = transactionID
        self.receiptImage = receiptImage
        self.note = note
        self.returned = returned
        self.isPrivate = isPrivate
    }

    /// Common lengths, offered when adding one: 14 or 30 days to return, 1 or 2 years' warranty.
    public static let returnWindows = [14, 28, 30, 60, 90]
    public static let warrantyYears = [1, 2, 3, 5]
}

/// How much a receipt's dates need looking at now, for chips and Plan.
public enum CoverUrgency: Hashable, Sendable {
    /// The return window closes soon.
    case returnBy(Date, days: Int)
    /// The warranty runs out soon.
    case warrantyEnds(Date, days: Int)

    public var date: Date {
        switch self { case .returnBy(let date, _), .warrantyEnds(let date, _): date }
    }

    public var days: Int {
        switch self { case .returnBy(_, let days), .warrantyEnds(_, let days): days }
    }

    /// Red for a return in the next 3 days; amber otherwise.
    public var isUrgent: Bool {
        if case .returnBy(_, let days) = self { return days <= 3 }
        return false
    }
}

public struct CoverWatch: Sendable {
    public var calendar: Calendar
    /// Returns closing within this many days are flagged.
    public var returnLeadDays = 7
    /// Warranties ending within this many days are flagged.
    public var warrantyLeadDays = 30

    public init(calendar: Calendar = .current) { self.calendar = calendar }

    private func days(from now: Date, to date: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// What needs looking at now, the return first. Nil when nothing does.
    public func urgency(_ cover: ProductCover, now: Date = Date()) -> CoverUrgency? {
        if cover.returned != true, let returnBy = cover.returnBy {
            let left = days(from: now, to: returnBy)
            if left >= 0 && left <= returnLeadDays { return .returnBy(returnBy, days: left) }
        }
        if let ends = cover.warrantyEnds {
            let left = days(from: now, to: ends)
            if left >= 0 && left <= warrantyLeadDays { return .warrantyEnds(ends, days: left) }
        }
        return nil
    }

    /// Still returnable or under warranty, soonest date first.
    public func active(_ covers: [ProductCover], now: Date = Date()) -> [ProductCover] {
        let today = calendar.startOfDay(for: now)
        func next(_ cover: ProductCover) -> Date? {
            [cover.returned == true ? nil : cover.returnBy, cover.warrantyEnds].compactMap { $0 }.filter { $0 >= today }.min()
        }
        return covers.filter { next($0) != nil }.sorted { next($0)! < next($1)! }
    }
}

extension ReminderPlanner {
    /// Return and warranty reminders: 3 days before the last day to return, and 30 days
    /// before a warranty ends, at the same hour as the contract reminders.
    public func reminders(for covers: [ProductCover], now: Date) -> [ContractReminder] {
        var result: [ContractReminder] = []
        for cover in covers {
            let name = cover.item.isEmpty ? cover.shop : cover.item
            if cover.returned != true, let returnBy = cover.returnBy,
               let fire = fireDate(daysBefore: 3, returnBy), fire > now {
                result.append(ContractReminder(contractID: cover.id, kind: .returnBy, fireDate: fire, eventDate: returnBy,
                                               title: "Last days to return \(name)",
                                               body: "It can go back to \(cover.shop) until \(dayText(returnBy)). The receipt is in Duo Budget."))
            }
            if let ends = cover.warrantyEnds, let fire = fireDate(daysBefore: contractEndLeadDays, ends), fire > now {
                result.append(ContractReminder(contractID: cover.id, kind: .warrantyEnds, fireDate: fire, eventDate: ends,
                                               title: "\(name) warranty ends soon",
                                               body: "The warranty runs out on \(dayText(ends)). Report any faults before then."))
            }
        }
        return result.sorted { $0.fireDate < $1.fireDate }
    }
}
