import Foundation

/// A subscription or bill that now costs more than before.
public struct PriceRise: Identifiable, Hashable, Sendable {
    public var id: UUID { contractID }
    public let contractID: UUID
    public let vendor: String
    public let previous: Decimal
    public let latest: Decimal
    public let date: Date

    public var increase: Decimal { latest - previous }
    /// The rise as a share of the old price, e.g. 0.125 for 12.5%.
    public var percent: Double { previous > 0 ? NSDecimalNumber(decimal: increase / previous).doubleValue : 0 }
}

public extension SubscriptionTracker {
    /// The latest payment against the one before (or the expected amount when there's only
    /// one). Small wobbles (under 1% or 50p) aren't rises.
    func priceRise(for contract: SubscriptionContract, transactions: [BankTransaction]) -> PriceRise? {
        guard contract.status == .active else { return nil }
        let paid = payments(for: contract, transactions: transactions)
        guard let latest = paid.last else { return nil }
        let previous = paid.count >= 2 ? paid[paid.count - 2].amount : contract.expectedAmount
        let rise = latest.amount - previous
        guard previous > 0, rise >= Decimal(string: "0.5")!, rise * 100 >= previous else { return nil }
        return PriceRise(contractID: contract.id, vendor: contract.vendor, previous: previous, latest: latest.amount, date: latest.date)
    }

    func priceRises(_ contracts: [SubscriptionContract], transactions: [BankTransaction]) -> [PriceRise] {
        contracts.compactMap { priceRise(for: $0, transactions: transactions) }.sorted { $0.date > $1.date }
    }
}

/// How much can be spent today and stay within the month: what's left in the budgets, less
/// bills still to come this month, shared over the days left (today included).
public struct SafeToSpend: Hashable, Sendable {
    public let today: Decimal
    public let left: Decimal
    public let billsStillToCome: Decimal
    public let daysLeft: Int

    public static func calculate(report: MonthlyBudgetReport, upcomingBills: [UpcomingItem], today: Date, calendar: Calendar = .current) -> SafeToSpend? {
        let limits = report.lines.compactMap(\.limit)
        guard !limits.isEmpty,
              let monthEnd = calendar.dateInterval(of: .month, for: report.month)?.end,
              calendar.isDate(today, equalTo: report.month, toGranularity: .month) else { return nil }
        let spent = report.lines.filter { $0.limit != nil }.reduce(Decimal(0)) { $0 + $1.spent }
        let left = limits.reduce(0, +) - spent
        let bills = upcomingBills
            .filter { $0.kind == .payment && $0.date >= calendar.startOfDay(for: today) && $0.date < monthEnd }
            .reduce(Decimal(0)) { $0 + ($1.amount ?? 0) }
        let days = max(1, (calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: monthEnd).day ?? 1))
        var perDay = max(0, left - bills) / Decimal(days)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &perDay, 2, .down)
        return SafeToSpend(today: rounded, left: left, billsStillToCome: bills, daysLeft: days)
    }
}

/// A receipt that looks like one already scanned: same shop, same total, within a day.
public enum ReceiptDuplicates {
    public static func match(_ editor: ReceiptDraftEditor, pending: [PendingReceipt], transactions: [BankTransaction], calendar: Calendar = .current) -> String? {
        guard let total = editor.receiptTotal ?? (editor.items.isEmpty ? nil : editor.splitTotal), total > 0 else { return nil }
        let shop = Categoriser.merchantKey(editor.merchant)
        func same(_ other: ReceiptDraftEditor) -> Bool {
            guard (other.receiptTotal ?? other.splitTotal) == total else { return false }
            if !shop.isEmpty, Categoriser.merchantKey(other.merchant) != shop { return false }
            switch (editor.purchaseDate, other.purchaseDate) {
            case let (a?, b?): return abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 9) <= 1
            default: return true
            }
        }
        if let earlier = pending.first(where: { same($0.editor) }) {
            return "Looks like a receipt you already saved (\(earlier.editor.merchant), waiting for its payment)."
        }
        for transaction in transactions {
            guard let receipt = transaction.pendingSplitDraft?.receipt else { continue }
            let other = ReceiptDraftEditor(merchant: receipt.merchant, purchaseDate: receipt.purchaseDate, receiptTotal: receipt.total, items: receipt.items)
            if same(other) { return "Looks like the receipt already attached to \(transaction.merchant)." }
        }
        for transaction in transactions where !transaction.splits.isEmpty {
            let paid = transaction.amount < 0 ? -transaction.amount : transaction.amount
            if paid == total, Categoriser.merchantKey(transaction.merchant).hasPrefix(shop.split(separator: " ").first.map(String.init) ?? "\u{0}"),
               editor.purchaseDate.map({ abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: $0), to: calendar.startOfDay(for: transaction.date)).day ?? 9) <= 3 }) ?? true {
                return "\(transaction.merchant) for this amount already has its receipt items."
            }
        }
        return nil
    }
}
