import Foundation

/// Finds money moving between your own accounts, so it never counts as spending or income:
/// - the two sides of one transfer (£800 out of NatWest, £800 into first direct a day later),
/// - credit card bills paid from the bank ("DD AMERICAN EXPRESS", "DD HSBC CARD PYMT"),
/// - payments to or from your own names ("CR KUMAR N", "SO KUMAR N&S FAMILY"),
/// - top-ups of your own Revolut or Monzo, and money put into savings such as NS&I.
/// A category you chose yourself is never changed.
public enum TransferDetector {
    public struct Change: Hashable, Sendable {
        public let category: String
        public let subcategory: String?
    }

    static let betweenAccounts = Change(category: "Internal transfer", subcategory: "Between accounts")
    static let cardRepayment = Change(category: "Card payment", subcategory: "Credit card repayment")
    static let savings = Change(category: "Savings & investments", subcategory: "Savings")

    /// Words on a bank statement for paying a credit card bill.
    static let cardBillWords = ["AMERICAN EXPRESS", "AMEX", "CAPITAL ONE", "BARCLAYCARD", "MBNA", "CARD PYMT", "CARD PAYMENT",
                                "CREDIT CARD", "VANQUIS", "AQUA CARD", "TESCO BANK", "JOHN LEWIS FINANCE", "NEWDAY"]
    /// Words on a card statement for the bill being paid.
    static let cardPaidWords = ["PAYMENT THANK YOU", "PAYMENT THANKYOU", "PAYMENT RECEIVED", "DIRECT DEBIT PAYMENT", "DD PAYMENT"]
    /// Your own e-money accounts, topped up from the bank.
    static let topUpWords = ["REVOLUT", "MONZO", "TOP UP", "TOPUP"]
    static let savingsWords = ["NS I", "NS AND I", "NSANDI", "PREMIUM BONDS", "SAVINGS ACCOUNT", "ISA"]
    /// Pay that happens to mention your name isn't a transfer.
    static let incomeWords = ["SALARY", "PAYROLL", "WAGES", "PENSION", "HMRC", "DIVIDEND", "REFUND"]
    /// Words in an account's name that make it a credit card.
    static let cardAccountWords = ["CARD", "AMEX", "AMERICAN EXPRESS", "CAPITAL ONE", "BARCLAYCARD", "MBNA"]

    /// The most days between the two sides of one transfer.
    public static let pairWindow = 4
    /// Small amounts are left alone: two £5 payments are too likely to be a coincidence.
    public static let smallestPair: Decimal = 10

    /// The transfers among `transactions`, by fingerprint, with the category each should have.
    /// Payments already in the right category are left out.
    /// - Parameters:
    ///   - names: the account holders' names, e.g. "NISHANT KUMAR".
    public static func detect(_ transactions: [BankTransaction], accounts: [BankAccount], names: [String], calendar: Calendar = .current) -> [String: Change] {
        let candidates = transactions.filter { $0.categoryChosen != true && $0.splits.isEmpty && $0.amount != 0 }
        let people = names.compactMap(Person.init)
        let cardAccounts = Set(accounts.filter { account in
            let words = " " + Categoriser.words(account.name).joined(separator: " ") + " "
            return cardAccountWords.contains { words.contains(" \($0) ") }
        }.map(\.id))
        var found: [String: Change] = [:]

        // 1. Both sides of one transfer: equal amounts, opposite signs, different accounts.
        var usedCredits = Set<String>()
        let credits = candidates.filter { $0.amount >= smallestPair && $0.accountID != nil }
        for debit in candidates.sorted(by: { $0.date < $1.date }) where debit.amount <= -smallestPair {
            guard let from = debit.accountID else { continue }
            let match = credits
                .filter { !usedCredits.contains($0.id) && $0.accountID != from && $0.amount == -debit.amount }
                .map { (credit: $0, days: abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: debit.date), to: calendar.startOfDay(for: $0.date)).day ?? 99)) }
                .filter { $0.days <= pairWindow && !mentions(incomeWords, in: $0.credit) }
                .min { $0.days < $1.days }
            guard let credit = match?.credit else { continue }
            usedCredits.insert(credit.id)
            let change = cardAccounts.contains(credit.accountID!) || mentions(cardBillWords, in: debit) ? cardRepayment : betweenAccounts
            found[debit.id] = change
            found[credit.id] = change
        }

        // 2. One side only, known from its words.
        for transaction in candidates where found[transaction.id] == nil {
            if let change = change(for: transaction, people: people, cardAccounts: cardAccounts) { found[transaction.id] = change }
        }
        return found.filter { id, change in
            guard let transaction = transactions.first(where: { $0.id == id }) else { return false }
            return transaction.category != change.category || transaction.subcategory != change.subcategory
        }
    }

    static func change(for transaction: BankTransaction, people: [Person], cardAccounts: Set<UUID>) -> Change? {
        let isCredit = transaction.amount > 0
        if mentions(incomeWords, in: transaction) { return nil }
        if isCredit {
            if mentions(cardPaidWords, in: transaction) { return cardRepayment }
            if let account = transaction.accountID, cardAccounts.contains(account), mentions(["PAYMENT", "THANK YOU"], in: transaction) { return cardRepayment }
        } else {
            if mentions(cardBillWords, in: transaction) { return cardRepayment }
            if mentions(topUpWords, in: transaction) { return betweenAccounts }
            if mentions(savingsWords, in: transaction) { return savings }
        }
        let words = Set(Categoriser.words(transaction.merchant + " " + transaction.description))
        if people.contains(where: { $0.isNamed(in: words) }) { return betweenAccounts }
        return nil
    }

    static func mentions(_ phrases: [String], in transaction: BankTransaction) -> Bool {
        let text = " " + Categoriser.words(transaction.merchant + " " + transaction.description).joined(separator: " ") + " "
        return phrases.contains { phrase in text.contains(" " + Categoriser.words(phrase).joined(separator: " ") + " ") }
    }

    /// An account holder, recognised the ways banks write a name: "NISHANT KUMAR",
    /// "KUMAR N", "N KUMAR", or "KUMAR N&S" for a joint account.
    struct Person {
        let first: String
        let last: String

        init?(_ name: String) {
            let words = Categoriser.words(name).filter { !["MR", "MRS", "MS", "MISS", "DR"].contains($0) }
            guard words.count >= 2, let first = words.first, let last = words.last, last.count > 1 else { return nil }
            self.first = first
            self.last = last
        }

        func isNamed(in words: Set<String>) -> Bool {
            guard words.contains(last) else { return false }
            return words.contains(first) || words.contains(String(first.prefix(1)))
        }
    }
}
