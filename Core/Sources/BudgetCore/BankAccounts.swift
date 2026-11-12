import Foundation

/// A bank account or card that statements are imported from.
public struct BankAccount: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// The account number as the bank's files show it (OFX ACCTID or a CSV column). Only
    /// the last four digits are needed to recognise it, and only those are shown.
    public var number: String
    /// Last four digits of cards that pay from this account, as printed on receipts.
    public var cardEndings: [String]
    /// Hidden, with its transactions, from a partner the household is shared with.
    public var isPrivate: Bool?
    /// Whose account it is: a partner's account makes its spending theirs (and paid by them),
    /// a joint account makes it shared. Nil or mine changes nothing.
    public var owner: MoneyOwner?
    /// The account holders' names from its statements, e.g. ["NEIL PATEL", "SARA PATEL"],
    /// so a payment to one of you ("OBP NEIL PATEL") is known to be a transfer.
    public var holderNames: [String]?

    public init(id: UUID = UUID(), name: String, number: String = "", cardEndings: [String] = []) {
        self.id = id
        self.name = name
        self.number = number
        self.cardEndings = cardEndings
    }

    /// "Current account ••1234", or just the name without a number.
    public var label: String {
        let ending = Self.lastFour(number)
        return ending.isEmpty ? name : "\(name) ••\(ending)"
    }

    public static func lastFour(_ number: String) -> String {
        String(number.filter(\.isNumber).suffix(4))
    }
}

public enum BankAccounts {
    /// Sets whose money new transactions are from their account's owner. Owners already set are kept.
    public static func applyOwners(_ transactions: [BankTransaction], accounts: [BankAccount]) -> [BankTransaction] {
        transactions.map { transaction in
            guard transaction.owner == nil, let id = transaction.accountID,
                  let owner = accounts.first(where: { $0.id == id })?.owner, owner != .mine else { return transaction }
            var owned = transaction
            owned.owner = owner
            if owner == .partner { owned.paidBy = .partner }
            return owned
        }
    }

    /// The account a statement number belongs to, compared on the last four digits.
    public static func account(forNumber number: String, in accounts: [BankAccount]) -> BankAccount? {
        let ending = BankAccount.lastFour(number)
        guard !ending.isEmpty else { return nil }
        return accounts.first { BankAccount.lastFour($0.number) == ending }
    }

    /// The account a receipt was paid from, from the card ending printed on it ("VISA ****1234").
    public static func account(forReceiptText text: String, in accounts: [BankAccount]) -> BankAccount? {
        guard let ending = cardEnding(in: text) else { return nil }
        return accounts.first { $0.cardEndings.contains(ending) || BankAccount.lastFour($0.number) == ending }
    }

    /// The last four card digits printed on a receipt, after masking such as **** or XXXX.
    public static func cardEnding(in text: String) -> String? {
        let pattern = "(?i)(?:[*xX•]{2,}[ -]?)+(\\d{4})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Spending per account for a month: positive for purchases, refunds take away.
    /// Transactions without an account are under nil.
    public static func spendingByAccount(_ transactions: [BankTransaction], month: Date, calculator: BudgetCalculator = BudgetCalculator()) -> [UUID?: Decimal] {
        var totals: [UUID?: Decimal] = [:]
        for transaction in transactions where calculator.isInMonth(transaction.date, month) {
            let spent = calculator.allocations(of: transaction).reduce(Decimal(0)) { $0 + $1.1 }
            if spent != 0 { totals[transaction.accountID, default: 0] += spent }
        }
        return totals
    }
}
