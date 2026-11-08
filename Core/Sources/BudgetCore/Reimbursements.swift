import Foundation

// Money you paid that someone pays back: a work expense, a friend's share of a meal, a
// refund you're waiting for. A payment marked like this stops counting as your spending (all
// of it, or the part being paid back), and the credit that pays it back isn't income.

/// A payment someone else is paying back to you.
public struct Reimbursement: Codable, Hashable, Sendable {
    /// Who pays it back, e.g. "Work" or "Sam".
    public var from: String
    /// How much of the payment comes back. Never more than the payment.
    public var amount: Decimal
    /// When the money came back. Nil while you're still waiting.
    public var receivedOn: Date?
    /// The credit that paid it back, when it's on a statement.
    public var repaymentID: String?

    public init(from: String, amount: Decimal, receivedOn: Date? = nil, repaymentID: String? = nil) {
        self.from = from
        self.amount = amount
        self.receivedOn = receivedOn
        self.repaymentID = repaymentID
    }

    public var isReceived: Bool { receivedOn != nil }
}

extension BankTransaction {
    /// The part of a payment that's still your own spending once a reimbursement is taken off.
    /// Credits and payments with no reimbursement are unchanged.
    public var amountAfterReimbursement: Decimal {
        guard amount < 0, let reimbursement else { return amount }
        let back = min(max(reimbursement.amount, 0), -amount)
        return amount + back
    }

    /// True for a credit that pays back a payment you marked as reimbursed.
    public var isRepayment: Bool { amount > 0 && repays != nil }
}

/// Reimbursements across your payments.
public enum Reimbursements {
    public struct Outstanding: Identifiable, Hashable, Sendable {
        public var id: String { transaction.id }
        public let transaction: BankTransaction
        public var from: String { transaction.reimbursement?.from ?? "" }
        public var amount: Decimal { transaction.reimbursement.map { min($0.amount, -transaction.amount) } ?? 0 }
    }

    /// Payments still waiting to be paid back, oldest first.
    public static func outstanding(_ transactions: [BankTransaction]) -> [Outstanding] {
        transactions
            .filter { $0.amount < 0 && $0.reimbursement != nil && $0.reimbursement?.isReceived == false }
            .sorted { $0.date < $1.date }
            .map(Outstanding.init)
    }

    /// The total still owed back to you, by who owes it, biggest first.
    public static func owedBack(_ transactions: [BankTransaction]) -> [(from: String, amount: Decimal)] {
        var totals: [String: Decimal] = [:]
        for item in outstanding(transactions) { totals[item.from, default: 0] += item.amount }
        return totals.map { ($0.key, $0.value) }.sorted { $0.amount > $1.amount }
    }

    /// Credits that could be the repayment: exactly the amount being paid back, paid in from the
    /// day before the payment to 120 days after, and not already paying back something else.
    /// Closest in date first.
    public static func candidates(for payment: BankTransaction, in transactions: [BankTransaction]) -> [BankTransaction] {
        guard let reimbursement = payment.reimbursement else { return [] }
        let latest = payment.date.addingTimeInterval(120 * 86_400)
        let earliest = payment.date.addingTimeInterval(-86_400)
        return transactions
            .filter { credit in
                credit.amount > 0 && credit.amount == reimbursement.amount
                    && credit.date >= earliest && credit.date <= latest
                    && (credit.repays == nil || credit.repays == payment.id)
                    && !BudgetCalculator.transferCategories.contains(credit.category)
            }
            .sorted { abs($0.date.timeIntervalSince(payment.date)) < abs($1.date.timeIntervalSince(payment.date)) }
    }

    /// Who people have paid you back before, most used first, for quick picks.
    public static func payers(_ transactions: [BankTransaction]) -> [String] {
        var counts: [String: Int] = [:]
        for transaction in transactions {
            if let from = transaction.reimbursement?.from.trimmingCharacters(in: .whitespaces), !from.isEmpty { counts[from, default: 0] += 1 }
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }
}
