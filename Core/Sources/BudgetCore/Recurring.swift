import Foundation

/// A payment that comes round regularly, spotted from the statements: a direct debit,
/// standing order or subscription. Shown in Coming up beside the bills you add yourself.
public struct RecurringPayment: Identifiable, Hashable, Sendable {
    /// Stable across launches, so Coming up and price rises can refer to it.
    public let id: UUID
    public let name: String
    /// What the payments are matched on, e.g. "OCTOPUS ENERGY".
    public let key: String
    public let category: String
    public let period: BillingPeriod
    /// Days between payments when the period is custom, e.g. 14 for fortnightly.
    public let intervalDays: Int?
    /// The latest amount, positive.
    public let amount: Decimal
    public let lastDate: Date
    public let nextDate: Date
    public let count: Int
    public let accountID: UUID?

    /// As a contract, so Coming up, safe-to-spend and the balance forecast can use it.
    public func contract(currency: String) -> SubscriptionContract {
        SubscriptionContract(id: id, vendor: name, category: .other, startDate: lastDate, billingPeriod: period, customIntervalDays: intervalDays,
                             nextPaymentDueDate: nextDate, expectedAmount: amount, currency: currency, pricing: .variable, transactionMatchers: [key])
    }
}

public enum RecurringDetector {
    struct Cadence {
        let period: BillingPeriod
        let days: ClosedRange<Int>
        let intervalDays: Int?
    }

    static let cadences = [
        Cadence(period: .weekly, days: 6...8, intervalDays: nil),
        Cadence(period: .custom, days: 13...15, intervalDays: 14),
        Cadence(period: .monthly, days: 27...34, intervalDays: nil),
        Cadence(period: .quarterly, days: 85...97, intervalDays: nil),
        Cadence(period: .yearly, days: 355...376, intervalDays: nil),
    ]

    /// Bank codes for payments that repeat by design: direct debit and standing order.
    static let scheduledCodes: Set<String> = ["DD", "SO", "STO", "DDR"]

    /// Recurring payments, soonest next first. A series needs three payments at a steady
    /// interval, or two for a direct debit or standing order. Amounts may vary (energy bills
    /// do) but not wildly. Series that stopped before the statements end are left out.
    public static func detect(_ transactions: [BankTransaction], calendar: Calendar = .current) -> [RecurringPayment] {
        // Card bills, transfers and savings move your own money, so they aren't bills here.
        let payments = transactions.filter { $0.amount < 0 && !BudgetCalculator.transferCategories.contains($0.category) }
        // Each account's statements end on their own date.
        var ends: [UUID?: Date] = [:]
        for transaction in transactions { ends[transaction.accountID] = max(ends[transaction.accountID] ?? .distantPast, transaction.date) }
        var groups: [String: [BankTransaction]] = [:]
        for payment in payments {
            let key = seriesKey(payment.merchant)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(payment)
        }
        var found: [RecurringPayment] = []
        for (key, group) in groups {
            let dataEnd = ends[group.last?.accountID] ?? .distantPast
            if let payment = recurring(group, key: key, dataEnd: dataEnd, calendar: calendar) {
                found.append(payment)
                continue
            }
            // Several plans with one payee (two Apple subscriptions, two NS&I bonds): try each amount.
            for run in Dictionary(grouping: group, by: \.amount).values where run.count < group.count {
                if let payment = recurring(run, key: key, dataEnd: dataEnd, calendar: calendar) { found.append(payment) }
            }
        }
        return found.sorted { ($0.nextDate, $0.name) < ($1.nextDate, $1.name) }
    }

    static func recurring(_ run: [BankTransaction], key: String, dataEnd: Date, calendar: Calendar) -> RecurringPayment? {
        let sorted = run.sorted { $0.date < $1.date }
        guard sorted.count >= 2, let last = sorted.last else { return nil }
        let words = Categoriser.words(last.merchant + " " + last.description)
        let scheduled = words.first.map(scheduledCodes.contains) == true || ["DIRECT DEBIT", "STANDING ORDER"].contains(words.prefix(2).joined(separator: " "))
        guard sorted.count >= 3 || scheduled else { return nil }
        let gaps = zip(sorted, sorted.dropFirst()).map { calendar.dateComponents([.day], from: calendar.startOfDay(for: $0.date), to: calendar.startOfDay(for: $1.date)).day ?? 0 }
        guard let cadence = cadences.first(where: { cadence in gaps.allSatisfy { cadence.days.contains($0) } }) else { return nil }
        // Steady amounts: each within half of the median (energy and phone bills move a little).
        let amounts = sorted.map { -$0.amount }.sorted()
        let median = amounts[amounts.count / 2]
        guard median > 0, amounts.allSatisfy({ abs($0 - median) <= median / 2 }) else { return nil }
        let schedule = SubscriptionSchedule(calendar: calendar)
        guard let next = schedule.nextDate(after: last.date, period: cadence.period, customIntervalDays: cadence.intervalDays) else { return nil }
        // Stopped: the next one was due well before the statements end.
        let grace = max(7, (cadence.days.upperBound) / 2)
        guard let stale = calendar.date(byAdding: .day, value: grace, to: next), stale >= dataEnd else { return nil }
        let keyForID = key + "|" + "\(median)"
        return RecurringPayment(id: stableID(keyForID), name: displayName(last.merchant), key: key, category: last.category,
                                period: cadence.period, intervalDays: cadence.intervalDays, amount: -last.amount, lastDate: last.date,
                                nextDate: next, count: sorted.count, accountID: last.accountID)
    }

    /// Bank wording around the payee: codes, "Card Transaction", "VIS INT'L" and the like.
    static let bankWords: Set<String> = ["DD", "DDR", "SO", "STO", "BP", "FPO", "OBP", "CR", "MAS", "VIS", "INTL", "INT", "CARD", "TRANSACTION",
                                         "DIRECT", "DEBIT", "STANDING", "ORDER", "ONLINE", "PAYMENT", "POS", "CONTACTLESS", "PURCHASE", "TO", "ON", "AT",
                                         "LONDON", "GB", "GBR", "UK", "ENG", "INTERNET", "WWW", "COM", "LTD", "LIMITED", "PLC",
                                         "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// The payee's words: no bank wording, reference numbers, dates or single letters.
    static func payeeWords(_ merchant: String) -> [String] {
        Categoriser.words(merchant).filter { !bankWords.contains($0) && !$0.contains(where: \.isNumber) && $0.count > 1 }
    }

    /// What payments in one series share: the payee's first word, e.g. "SPOTIFY" for
    /// "Card Transaction 3531 19OCT26 SPOTIFY P48 LONDON GB". Two payees with one first word
    /// (Virgin Media, Virgin Atlantic) are told apart by their amounts.
    static func seriesKey(_ merchant: String) -> String {
        payeeWords(merchant).first ?? ""
    }

    /// "DD OCTOPUS ENERGY 1234" → "Octopus Energy".
    static func displayName(_ merchant: String) -> String {
        let words = payeeWords(merchant).prefix(3)
        guard !words.isEmpty else { return merchant }
        return words.map { word in
            word.count <= 3 || word.contains("&") ? word : word.prefix(1) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// The same UUID for the same series on every launch and device.
    static func stableID(_ text: String) -> UUID {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in text.utf8.reversed() { second = (second ^ UInt64(byte)) &* 0x100000001b3 }
        let bytes = withUnsafeBytes(of: hash.bigEndian) { Array($0) } + withUnsafeBytes(of: second.bigEndian) { Array($0) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6] & 0x0f | 0x40, bytes[7],
                           bytes[8] & 0x3f | 0x80, bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
