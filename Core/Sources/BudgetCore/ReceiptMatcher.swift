import Foundation

/// A bank payment a scanned receipt could belong to.
public struct ReceiptMatch: Identifiable, Hashable, Sendable {
    public var id: String { transaction.id }
    public let transaction: BankTransaction
    /// 0 to 1: how well the amount, date and shop name agree.
    public let score: Double
    /// The payment is exactly the receipt total.
    public let amountMatches: Bool

    public init(transaction: BankTransaction, score: Double, amountMatches: Bool) {
        self.transaction = transaction
        self.score = score
        self.amountMatches = amountMatches
    }
}

/// Finds which card payment a receipt is for, using the total, the date and the shop name.
public enum ReceiptMatcher {
    public static func candidates(
        for editor: ReceiptDraftEditor,
        in transactions: [BankTransaction],
        today: Date = Date(),
        limit: Int = 5,
        calendar: Calendar = .current
    ) -> [ReceiptMatch] {
        let total = editor.receiptTotal ?? editor.splitTotal
        let date = editor.purchaseDate ?? today
        let shop = Set(Categoriser.words(editor.merchant).filter { $0.count > 2 })
        let tolerance = SplitApprovalPolicy().tolerance

        func rank(_ transaction: BankTransaction) -> (match: ReceiptMatch, distance: TimeInterval) {
                let paid: Decimal = -transaction.amount
                let difference = abs(paid - total)
                let exact = difference <= tolerance
                var score = 0.0
                if exact {
                    score += 0.6
                } else if total > 0, difference / total <= Decimal(string: "0.2")! {
                    // Close but not equal, e.g. a tip added at the till.
                    let share = NSDecimalNumber(decimal: difference / total).doubleValue
                    score += 0.3 * (1 - share * 5)
                }
                let dayGap = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: transaction.date)).day ?? 99
                score += dateScore(abs(dayGap))
                let merchant = Set(Categoriser.words(transaction.merchant))
                if !shop.isEmpty, !shop.isDisjoint(with: merchant) { score += 0.15 }
                return (ReceiptMatch(transaction: transaction, score: score, amountMatches: exact), abs(transaction.date.timeIntervalSince(date)))
        }

        let ranked = transactions.filter { $0.amount < 0 && $0.splits.isEmpty }.map(rank)
        let sorted = ranked.sorted { lhs, rhs in
            lhs.match.score != rhs.match.score ? lhs.match.score > rhs.match.score : lhs.distance < rhs.distance
        }
        return sorted.prefix(limit).map(\.match)
    }

    /// Same day is best; a card payment often posts a day or two after the purchase.
    static func dateScore(_ days: Int) -> Double {
        switch days {
        case 0: 0.25
        case 1: 0.2
        case 2...3: 0.1
        case 4...7: 0.05
        default: 0
        }
    }
}
