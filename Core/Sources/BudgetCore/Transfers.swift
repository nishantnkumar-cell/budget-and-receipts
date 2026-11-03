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

    /// Words on a bank statement for paying a credit card bill. Not "CARD PAYMENT": banks such as
    /// Santander write ordinary debit card shopping as "CARD PAYMENT TO TESCO STORES".
    static let cardBillWords = ["AMERICAN EXPRESS", "AMEX", "CAPITAL ONE", "BARCLAYCARD", "MBNA", "CARD PYMT",
                                "CREDIT CARD", "VANQUIS", "AQUA CARD", "TESCO BANK", "JOHN LEWIS FINANCE", "NEWDAY"]
    /// Words a card statement uses for the bill being paid, wherever they appear.
    static let cardThanksWords = ["PAYMENT THANK YOU", "PAYMENT THANKYOU", "PAYMENT RECEIVED THANK YOU", "PAYMENT RECEIVED THANKYOU"]
    /// Words that mean the bill was paid only on a card account (or a line with no account):
    /// on a current account "FASTER PAYMENT RECEIVED" is money from someone else.
    static let cardPaidWords = cardThanksWords + ["PAYMENT RECEIVED", "DIRECT DEBIT PAYMENT", "DD PAYMENT"]
    /// Your own e-money accounts, topped up from the bank. Not "TOP UP": a phone or Oyster
    /// top-up ("VODAFONE TOP UP") is spending.
    static let topUpWords = ["REVOLUT", "MONZO"]
    /// Bank codes for money moved by transfer rather than spent with a card.
    static let transferCodes = ["OBP", "FPO", "FPI", "TFR", "TRANSFER", "STO", "SO"]
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
            guard let credit = match?.credit,
                  looksLikeTransfer(debit, credit, people: people, cardAccounts: cardAccounts) else { continue }
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
            if mentions(cardThanksWords, in: transaction) { return cardRepayment }
            let onCard = transaction.accountID.map(cardAccounts.contains) ?? true
            if onCard, mentions(cardPaidWords, in: transaction) { return cardRepayment }
            if let account = transaction.accountID, cardAccounts.contains(account), mentions(["PAYMENT", "THANK YOU"], in: transaction) { return cardRepayment }
        } else {
            if mentions(cardBillWords, in: transaction) { return cardRepayment }
            if mentions(topUpWords, in: transaction) { return betweenAccounts }
            if mentions(savingsWords, in: transaction) { return savings }
        }
        if namesAHolder(transaction, people: people) { return betweenAccounts }
        return nil
    }

    static func namesAHolder(_ transaction: BankTransaction, people: [Person]) -> Bool {
        let words = Categoriser.words(transaction.merchant + " " + transaction.description)
        return people.contains { $0.isNamed(in: words) }
    }

    /// Equal and opposite amounts in two accounts happen by chance too (a £30 shop on one card,
    /// £30 paid back to the other). They pair only when neither is a purchase or refund the app
    /// recognised, or when either side's wording says money was moved.
    static func looksLikeTransfer(_ debit: BankTransaction, _ credit: BankTransaction, people: [Person], cardAccounts: Set<UUID>) -> Bool {
        let spending = Set(FinanceCategories.budgetable)
        if !spending.contains(debit.category) && !spending.contains(credit.category) { return true }
        if let account = credit.accountID, cardAccounts.contains(account) { return true }
        return [debit, credit].contains { side in
            mentions(transferCodes + cardBillWords + cardThanksWords + topUpWords + savingsWords, in: side) || namesAHolder(side, people: people)
        }
    }

    static func mentions(_ phrases: [String], in transaction: BankTransaction) -> Bool {
        let text = " " + Categoriser.words(transaction.merchant + " " + transaction.description).joined(separator: " ") + " "
        return phrases.contains { phrase in text.contains(" " + Categoriser.words(phrase).joined(separator: " ") + " ") }
    }

    /// An account holder, recognised the ways banks write a holder's name: "NISHANT KUMAR",
    /// "KUMAR N", or "KUMAR N&S" for a joint account. "N KUMAR" alone is not enough: that is
    /// how a payee you typed reads, and many people share a surname and an initial.
    struct Person {
        let first: String
        let last: String

        init?(_ name: String) {
            let words = Categoriser.words(name).filter { !["MR", "MRS", "MS", "MISS", "DR"].contains($0) }
            guard words.count >= 2, let first = words.first, let last = words.last, last.count > 1 else { return nil }
            self.first = first
            self.last = last
        }

        func isNamed(in words: [String]) -> Bool {
            guard words.contains(last) else { return false }
            if words.contains(first) { return true }
            // Surname first, then the initial: the way banks print an account holder.
            let initial = String(first.prefix(1))
            return zip(words, words.dropFirst()).contains { $0 == last && $1 == initial }
        }
    }
}
