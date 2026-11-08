import Foundation

// Holidays and other trips abroad: what each payment cost in the other currency, the
// exchange rate you got, the card fees on top, and a total per trip.

/// An amount paid in another currency, with what the card charged on top.
public struct ForeignAmount: Codable, Hashable, Sendable {
    /// What was paid in the other currency, e.g. 42.50.
    public var amount: Decimal
    /// The ISO code, e.g. "EUR".
    public var currency: String
    /// A fee the card added to this payment, in your own currency. Nil when the fee is its
    /// own line on the statement, or there wasn't one.
    public var fee: Decimal?

    public init(amount: Decimal, currency: String, fee: Decimal? = nil) {
        self.amount = amount
        self.currency = currency.uppercased()
        self.fee = fee
    }

    /// Units of the other currency you got for one unit of yours, e.g. 1.1622 euros a pound,
    /// from what the payment cost at home without its fee. Nil when it can't be worked out.
    public func rate(homeAmount: Decimal) -> Decimal? {
        let paid = abs(homeAmount) - (fee ?? 0)
        guard paid > 0, amount > 0 else { return nil }
        var rate = amount / paid
        var rounded = Decimal()
        NSDecimalRound(&rounded, &rate, 4, .plain)
        return rounded
    }
}

/// A holiday or trip: payments in its dates (or added by hand) add up to one total.
public struct Trip: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var start: Date
    public var end: Date
    /// The currency used there, e.g. "EUR". Nil for a trip at home.
    public var currency: String?
    /// What you meant to spend, in your own currency.
    public var budget: Decimal?
    /// Payments in the trip's dates you took out of it.
    public var excluded: [String]?
    /// Whose trip it is. Nil or shared is both of you.
    public var owner: MoneyOwner?
    public var isPrivate: Bool?

    public init(id: UUID = UUID(), name: String, start: Date, end: Date, currency: String? = nil, budget: Decimal? = nil,
                excluded: [String]? = nil, owner: MoneyOwner? = nil, isPrivate: Bool? = nil) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.currency = currency
        self.budget = budget
        self.excluded = excluded
        self.owner = owner
        self.isPrivate = isPrivate
    }

    /// True when the date falls on any day from the first to the last day of the trip.
    public func covers(_ date: Date, calendar: Calendar = .current) -> Bool {
        let first = calendar.startOfDay(for: start)
        guard let afterLast = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(start, end))) else { return false }
        return date >= first && date < afterLast
    }
}

public enum TripLedger {
    /// Spending categories that are part of a trip even when paid before it (flights, hotels).
    static let bookedAhead: Set<String> = ["Travel"]

    /// Whether a payment is a card's foreign transaction fee.
    public static func isCardFee(_ transaction: BankTransaction) -> Bool {
        if transaction.subcategory == "Foreign transaction fees" { return true }
        let text = (transaction.merchant + " " + transaction.description).uppercased()
        return ["NON STERLING", "NON-STERLING", "NON STG", "FOREIGN TRANSACTION FEE", "FX FEE", "FOREIGN EXCHANGE FEE",
                "FOREIGN CURRENCY FEE", "CASH FEE", "NON-GBP", "NON GBP"].contains { text.contains($0) }
    }

    /// The payments on a trip: those you added to it, plus spending in its dates that was
    /// paid in another currency or is a card fee. Transfers and income are left out.
    public static func payments(for trip: Trip, in transactions: [BankTransaction], calendar: Calendar = .current) -> [BankTransaction] {
        let excluded = Set(trip.excluded ?? [])
        return transactions.filter { transaction in
            guard !excluded.contains(transaction.id) else { return false }
            if transaction.tripID == trip.id { return true }
            guard transaction.tripID == nil, transaction.amount < 0, trip.covers(transaction.date, calendar: calendar),
                  !BudgetCalculator.transferCategories.contains(transaction.category) else { return false }
            return transaction.foreign != nil || isCardFee(transaction)
        }
        .sorted { $0.date > $1.date }
    }

    /// Spending in a trip's dates that isn't on it yet, for "Add everything from these dates".
    public static func suggestions(for trip: Trip, in transactions: [BankTransaction], calendar: Calendar = .current) -> [BankTransaction] {
        let onTrip = Set(payments(for: trip, in: transactions, calendar: calendar).map(\.id))
        return transactions.filter { transaction in
            transaction.amount < 0 && transaction.tripID == nil && !onTrip.contains(transaction.id)
                && trip.covers(transaction.date, calendar: calendar)
                && !BudgetCalculator.transferCategories.contains(transaction.category)
        }
    }

    public struct Summary: Sendable {
        public let payments: [BankTransaction]
        /// Everything the trip cost in your own currency, fees included, after reimbursements.
        public let total: Decimal
        /// Card fees: their own statement lines plus fees recorded on payments.
        public let fees: Decimal
        /// What was paid in the trip's currency, where the statement says.
        public let foreignTotal: Decimal
        /// The average rate you got: foreign units for one unit of yours, fees left out.
        public let averageRate: Decimal?
        /// Spending per category, biggest first.
        public let byCategory: [(category: String, amount: Decimal)]
        public let days: Int
        public var perDay: Decimal { days > 0 ? (total / Decimal(days)).roundedToPence : total }
        public let budget: Decimal?
        public var left: Decimal? { budget.map { $0 - total } }
    }

    public static func summary(for trip: Trip, in transactions: [BankTransaction], calendar: Calendar = .current) -> Summary {
        let payments = payments(for: trip, in: transactions, calendar: calendar)
        var fees = Decimal(0)
        var total = Decimal(0)
        var foreignTotal = Decimal(0)
        var homeForForeign = Decimal(0)
        var byCategory: [String: Decimal] = [:]
        for payment in payments {
            let cost = -payment.amountAfterReimbursement
            total += cost
            if isCardFee(payment) {
                fees += cost
                byCategory["Card fees", default: 0] += cost
                continue
            }
            let fee = payment.foreign?.fee ?? 0
            fees += fee
            if fee > 0 { byCategory["Card fees", default: 0] += fee }
            byCategory[payment.splits.first?.category ?? payment.category, default: 0] += cost - fee
            if let foreign = payment.foreign, foreign.currency == (trip.currency ?? foreign.currency) {
                foreignTotal += foreign.amount
                homeForForeign += -payment.amount - fee
            }
        }
        var rate: Decimal?
        if homeForForeign > 0, foreignTotal > 0 {
            var value = foreignTotal / homeForForeign
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 4, .plain)
            rate = rounded
        }
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: trip.start), to: calendar.startOfDay(for: max(trip.start, trip.end))).day ?? 0) + 1
        return Summary(payments: payments, total: total, fees: fees, foreignTotal: foreignTotal, averageRate: rate,
                       byCategory: byCategory.filter { $0.value != 0 }.map { ($0.key, $0.value) }.sorted { $0.amount > $1.amount },
                       days: days, budget: trip.budget)
    }
}

/// Reads the other-currency amount, rate and fee that statements print beside a payment, e.g.
/// "EUR 42.50 @ 1.1622", "42.50 USD RATE 1.2650" or "VISA EXCHANGE RATE 1.16 ... FEE 1.23".
public enum ForeignAmountReader {
    static let currencies = ["EUR", "USD", "CHF", "JPY", "AUD", "CAD", "NZD", "SEK", "NOK", "DKK", "PLN", "CZK", "HUF",
                             "TRY", "AED", "INR", "THB", "SGD", "HKD", "ZAR", "MXN", "ISK", "HRK", "RON", "BGN", "MAD",
                             "EGP", "CNY", "KRW", "IDR", "MYR", "PHP", "VND", "BRL", "GBP", "LKR", "QAR", "SAR"]

    public static func read(_ text: String, home: String) -> ForeignAmount? {
        let upper = text.uppercased()
        let codes = currencies.filter { $0 != home.uppercased() }.joined(separator: "|")
        let number = #"(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)"#
        let patterns = [#"\b(\#(codes))\s*"# + number, number + #"\s*(\#(codes))\b"#]
        var found: (Decimal, String)?
        for (index, pattern) in patterns.enumerated() {
            guard let match = firstMatch(pattern, in: upper) else { continue }
            let code = match[index == 0 ? 1 : 2], value = match[index == 0 ? 2 : 1]
            if let amount = Decimal(string: value.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")), amount > 0 {
                found = (amount, code)
                break
            }
        }
        guard let (amount, code) = found else { return nil }
        var fee: Decimal?
        if let match = firstMatch(#"(?:FEE|COMMISSION|CHARGE)\S*\s*(?:£|\$|€)?\s*(\d+\.\d{2})"#, in: upper) {
            fee = Decimal(string: match[1], locale: Locale(identifier: "en_US_POSIX"))
        }
        return ForeignAmount(amount: amount, currency: code, fee: fee)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// Fills in the foreign amount on payments whose statement text shows one. Payments that
    /// already have one (read before, or entered by hand) are left alone. Returns the ids changed.
    public static func fill(_ transactions: inout [BankTransaction], home: String) -> [String] {
        var changed: [String] = []
        for index in transactions.indices where transactions[index].foreign == nil && transactions[index].amount < 0 {
            let text = transactions[index].merchant + " " + transactions[index].description
            if let foreign = read(text, home: home) {
                transactions[index].foreign = foreign
                changed.append(transactions[index].id)
            }
        }
        return changed
    }
}

extension Decimal {
    /// Rounded to two decimal places, as money is.
    public var roundedToPence: Decimal {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .bankers)
        return rounded
    }
}
