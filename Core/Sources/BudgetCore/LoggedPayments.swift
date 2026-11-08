import Foundation

// Payments logged as they happen (an Apple Pay tap run through Shortcuts, or "log a payment"
// with Siri) wait for the statement. When the statement brings the same payment, the two
// become one: the statement's line is kept, with what you added to the logged one.

extension BankTransaction {
    /// Fingerprint prefix for payments logged from Shortcuts or Siri.
    public static let loggedPrefix = "logged:"

    /// True for a payment logged from Shortcuts or Siri that no statement has brought in yet.
    public var isLogged: Bool { fingerprint.hasPrefix(Self.loggedPrefix) }

    /// A payment logged from Shortcuts or Siri, e.g. by an Apple Pay automation.
    public static func logged(amount: Decimal, merchant: String, card: String? = nil, date: Date = Date(), accountID: UUID? = nil, category: String = "Uncategorised") -> BankTransaction {
        var transaction = BankTransaction(
            date: date,
            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Apple Pay" : merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            description: card.map { "Logged with Apple Pay, \($0)" } ?? "Logged with Shortcuts",
            amount: -abs(amount),
            category: category,
            fingerprint: loggedPrefix + UUID().uuidString
        )
        transaction.accountID = accountID
        return transaction
    }
}

public enum LoggedPaymentMatcher {
    public struct Match: Hashable, Sendable {
        public let logged: String
        public let statement: String
    }

    /// The statement line can be posted a day before (time zones) to six days after the tap.
    static let earliest: TimeInterval = -1 * 86_400
    static let latest: TimeInterval = 6 * 86_400

    /// Pairs each logged payment with the statement line that is surely the same payment:
    /// the same amount, from the same card when the logged one says, posted within the window.
    /// When two lines could be the one, the shop name decides; if it still can't, the logged
    /// payment waits (it shows under Possible copies instead of being merged wrongly).
    public static func match(_ transactions: [BankTransaction], calendar: Calendar = .current) -> [Match] {
        let logged = transactions.filter(\.isLogged).sorted { $0.date < $1.date }
        var available = transactions.filter { !$0.isLogged && !$0.fingerprint.hasPrefix("manual") && $0.amount < 0 }
        var result: [Match] = []
        for payment in logged {
            let candidates = available.filter { line in
                let gap = calendar.startOfDay(for: line.date).timeIntervalSince(calendar.startOfDay(for: payment.date))
                // Paid in another currency: the statement's amount is in yours, so only the shop can tell.
                let sameAmount = payment.loggedCurrency != nil || line.amount == payment.amount
                return sameAmount && gap >= earliest && gap <= latest
                    && (payment.accountID == nil || line.accountID == nil || payment.accountID == line.accountID)
            }
            let chosen = payment.loggedCurrency == nil ? best(candidates, for: payment, calendar: calendar) : sameShop(candidates, as: payment)
            guard let chosen else { continue }
            result.append(Match(logged: payment.id, statement: chosen.id))
            available.removeAll { $0.id == chosen.id }
        }
        return result
    }

    /// The one line from the same shop, for a payment logged in another currency.
    private static func sameShop(_ candidates: [BankTransaction], as payment: BankTransaction) -> BankTransaction? {
        let words = Set(Categoriser.matchWords(payment.merchant).filter { $0.count > 2 })
        let named = candidates.filter { !words.isDisjoint(with: Categoriser.matchWords($0.merchant)) }
        return named.count == 1 ? named[0] : nil
    }

    private static func best(_ candidates: [BankTransaction], for payment: BankTransaction, calendar: Calendar) -> BankTransaction? {
        let words = Set(Categoriser.matchWords(payment.merchant).filter { $0.count > 2 })
        let named = candidates.filter { !words.isDisjoint(with: Categoriser.matchWords($0.merchant)) }
        if candidates.count == 1 {
            // One line of that amount: it's the one when the shop agrees or it came soon after.
            let line = candidates[0]
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: payment.date), to: calendar.startOfDay(for: line.date)).day ?? 99
            return !named.isEmpty || days <= 3 ? line : nil
        }
        return named.count == 1 ? named[0] : nil
    }

    /// The statement line with what you added to the logged payment carried over: category
    /// (when you chose it or the statement's is unknown), whose it is, tags, trip, receipt and
    /// the rest. Date, amount and wording stay the statement's.
    public static func merged(statement: BankTransaction, logged: BankTransaction) -> BankTransaction {
        var result = statement
        if logged.categoryChosen == true || (statement.category == "Uncategorised" && logged.category != "Uncategorised") {
            result.category = logged.category
            result.subcategory = logged.subcategory
            result.categoryChosen = logged.categoryChosen
        }
        if result.splits.isEmpty { result.splits = logged.splits }
        result.pendingSplitDraft = result.pendingSplitDraft ?? logged.pendingSplitDraft
        result.owner = result.owner ?? logged.owner
        result.paidBy = result.paidBy ?? logged.paidBy
        result.isPrivate = (result.isPrivate == true || logged.isPrivate == true) ? true : nil
        let tags = Array(Set((result.tags ?? []) + (logged.tags ?? []))).sorted()
        result.tags = tags.isEmpty ? nil : tags
        result.tripID = result.tripID ?? logged.tripID
        result.reimbursement = result.reimbursement ?? logged.reimbursement
        result.foreign = result.foreign ?? logged.foreign
        return result
    }
}
