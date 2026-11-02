import Foundation

/// A bank payment a scanned receipt could belong to.
public struct ReceiptMatch: Identifiable, Hashable, Sendable {
    public var id: String { transaction.id }
    public let transaction: BankTransaction
    /// 0 to 1: how well the amount, date and shop name agree.
    public let score: Double
    /// The payment is exactly the receipt total.
    public let amountMatches: Bool
    /// Days from the receipt date to the statement date: positive when the payment posted later.
    public let dayGap: Int
    public let sameShop: Bool
    /// The card on the receipt belongs to the account this payment is from.
    public let sameAccount: Bool

    public init(transaction: BankTransaction, score: Double, amountMatches: Bool, dayGap: Int = 0, sameShop: Bool = false, sameAccount: Bool = false) {
        self.transaction = transaction
        self.score = score
        self.amountMatches = amountMatches
        self.dayGap = dayGap
        self.sameShop = sameShop
        self.sameAccount = sameAccount
    }
}

/// A scanned receipt that has no bank payment yet. Card payments can reach the statement
/// days after the purchase, so a receipt waits here until a statement brings its payment.
public struct PendingReceipt: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var scannedAt: Date
    public var editor: ReceiptDraftEditor
    /// Hidden from a partner the household is shared with.
    public var isPrivate: Bool?

    public init(id: UUID = UUID(), scannedAt: Date = Date(), editor: ReceiptDraftEditor) {
        self.id = id
        self.scannedAt = scannedAt
        self.editor = editor
    }

    /// The day to match on: the date printed on the receipt, else the day it was scanned.
    public var purchaseDate: Date { editor.purchaseDate ?? scannedAt }
}

/// How far apart the receipt date and the statement date may be. A payment usually posts
/// on the day or a few days later (longer over weekends and bank holidays, or for hotels
/// and fuel); it rarely posts before the date on the receipt.
public struct MatchWindow: Hashable, Sendable {
    public var daysBefore: Int
    public var daysAfter: Int

    public init(daysBefore: Int = 2, daysAfter: Int = 7) {
        self.daysBefore = daysBefore
        self.daysAfter = daysAfter
    }

    public func contains(_ dayGap: Int) -> Bool { (-daysBefore...daysAfter).contains(dayGap) }
}

/// Finds which card payment a receipt is for, using the total, the date and the shop name.
public enum ReceiptMatcher {
    public static func candidates(
        for editor: ReceiptDraftEditor,
        in transactions: [BankTransaction],
        today: Date = Date(),
        limit: Int = 5,
        account: UUID? = nil,
        calendar: Calendar = .current
    ) -> [ReceiptMatch] {
        let date = editor.purchaseDate ?? today
        let ranked = transactions.filter(isOpenPayment).map { rank($0, for: editor, date: date, account: account, calendar: calendar) }
        let sorted = ranked.sorted { lhs, rhs in
            lhs.match.score != rhs.match.score ? lhs.match.score > rhs.match.score : lhs.distance < rhs.distance
        }
        return sorted.prefix(limit).map(\.match)
    }

    /// Pairs waiting receipts with payments from a new statement. A receipt is matched only
    /// when exactly one open payment has its exact total inside the date window (or exactly
    /// one of those is from the same shop or the card's account), and no other waiting receipt
    /// wants that payment. When the receipt shows which account paid (`accountFor`), payments
    /// from other accounts are never matched.
    /// Anything less certain stays waiting, with suggestions, for the person to choose.
    public static func autoMatch(
        _ pending: [PendingReceipt],
        in transactions: [BankTransaction],
        window: MatchWindow = MatchWindow(),
        accountFor: (PendingReceipt) -> UUID? = { _ in nil },
        calendar: Calendar = .current
    ) -> [(receipt: PendingReceipt.ID, transaction: BankTransaction.ID)] {
        let open = transactions.filter(isOpenPayment)
        var wanted: [(PendingReceipt.ID, BankTransaction.ID)] = []
        for receipt in pending {
            let account = accountFor(receipt)
            let exact = open
                .filter { account == nil || $0.accountID == nil || $0.accountID == account }
                .map { rank($0, for: receipt.editor, date: receipt.purchaseDate, account: account, calendar: calendar).match }
                .filter { $0.amountMatches && window.contains($0.dayGap) }
            var pick: ReceiptMatch?
            if exact.count == 1 {
                pick = exact[0]
            } else {
                for clue in [\ReceiptMatch.sameAccount, \ReceiptMatch.sameShop] where pick == nil {
                    let narrowed = exact.filter { $0[keyPath: clue] }
                    if narrowed.count == 1 { pick = narrowed[0] }
                }
            }
            if let pick { wanted.append((receipt.id, pick.transaction.id)) }
        }
        // Two receipts wanting one payment is a coin toss: leave both for the person.
        let claims = Dictionary(grouping: wanted, by: \.1).mapValues(\.count)
        return wanted.filter { claims[$0.1] == 1 }.map { (receipt: $0.0, transaction: $0.1) }
    }

    /// Card payments with no receipt yet.
    static func isOpenPayment(_ transaction: BankTransaction) -> Bool {
        transaction.amount < 0 && transaction.splits.isEmpty && transaction.pendingSplitDraft == nil
    }

    private static func rank(_ transaction: BankTransaction, for editor: ReceiptDraftEditor, date: Date, account: UUID?, calendar: Calendar) -> (match: ReceiptMatch, distance: TimeInterval) {
        let total = editor.receiptTotal ?? editor.splitTotal
        let paid: Decimal = -transaction.amount
        let difference = abs(paid - total)
        let exact = difference <= SplitApprovalPolicy().tolerance
        var score = 0.0
        if exact {
            score += 0.6
        } else if total > 0, difference / total <= Decimal(string: "0.2")! {
            // Close but not equal, e.g. a tip added at the till.
            let share = NSDecimalNumber(decimal: difference / total).doubleValue
            score += 0.3 * (1 - share * 5)
        }
        let dayGap = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: transaction.date)).day ?? 99
        score += dateScore(dayGap)
        let shop = Set(Categoriser.words(editor.merchant).filter { $0.count > 2 })
        let sameShop = !shop.isEmpty && !shop.isDisjoint(with: Set(Categoriser.words(transaction.merchant)))
        if sameShop { score += 0.15 }
        let sameAccount = account != nil && transaction.accountID == account
        if sameAccount { score += 0.1 }
        let match = ReceiptMatch(transaction: transaction, score: score, amountMatches: exact, dayGap: dayGap, sameShop: sameShop, sameAccount: sameAccount)
        return (match, abs(transaction.date.timeIntervalSince(date)))
    }

    /// Days from the receipt to the statement line. Same day is best; posting a few days
    /// later is normal; a payment dated before the receipt is unusual.
    static func dateScore(_ dayGap: Int) -> Double {
        switch dayGap {
        case 0: 0.25
        case 1...3: 0.2
        case 4...7: 0.1
        case -2 ... -1: 0.1
        case 8...14: 0.03
        default: 0
        }
    }
}
