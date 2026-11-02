import Foundation

/// What an on-device language model read from a receipt's text. The apps fill this in
/// from Apple's Foundation Models; it is kept plain here so the checks below can be tested
/// anywhere, including on Windows.
public struct ReceiptAIReading: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var name: String
        public var amount: Decimal
        public var category: String?

        public init(name: String, amount: Decimal, category: String? = nil) {
            self.name = name
            self.amount = amount
            self.category = category
        }
    }

    public var merchant: String?
    /// The date as written on the receipt, e.g. "12/10/2026".
    public var date: String?
    public var subtotal: Decimal?
    public var vat: Decimal?
    public var total: Decimal?
    public var items: [Item]

    public init(merchant: String? = nil, date: String? = nil, subtotal: Decimal? = nil, vat: Decimal? = nil, total: Decimal? = nil, items: [Item] = []) {
        self.merchant = merchant
        self.date = date
        self.subtotal = subtotal
        self.vat = vat
        self.total = total
        self.items = items
    }
}

/// Decides when a receipt needs the language model, and checks its answer before using it.
/// A model can invent numbers, so only amounts that are printed on the receipt are kept.
public enum ReceiptAIMerge {
    /// The rules-based reading is good enough when it found items that add up to the total.
    public static func needsHelp(_ editor: ReceiptDraftEditor) -> Bool {
        guard !editor.items.isEmpty, let total = editor.receiptTotal else { return true }
        let tolerance = SplitApprovalPolicy().tolerance
        return abs(editor.splitTotal - total) > tolerance || editor.merchant.isEmpty
    }

    /// Combines the two readings. The model's items replace the parsed ones only when every
    /// amount appears in the receipt text and they add up to the total better than before.
    public static func merge(_ ai: ReceiptAIReading, into parsed: ReceiptDraftEditor, calendar: Calendar = .current) -> ReceiptDraftEditor {
        let printed = printedAmounts(in: parsed.rawText)
        func onReceipt(_ value: Decimal?) -> Decimal? { value.flatMap { printed.contains($0) ? $0 : nil } }

        var result = parsed
        if result.merchant.isEmpty || needsHelp(parsed), let merchant = ai.merchant?.trimmingCharacters(in: .whitespacesAndNewlines), !merchant.isEmpty {
            result.merchant = merchant
        }
        if result.purchaseDate == nil, let date = ai.date {
            result.purchaseDate = ReceiptParser.date(in: date, calendar: calendar)
        }
        result.subtotal = result.subtotal ?? onReceipt(ai.subtotal)
        result.tax = result.tax ?? onReceipt(ai.vat)
        let parsedTotal = result.receiptTotal.flatMap { printed.contains($0) ? $0 : nil }
        let aiTotal = onReceipt(ai.total)
        let tolerance = SplitApprovalPolicy().tolerance

        let aiItems = ai.items.compactMap { item -> ReceiptLineItem? in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, item.amount > 0, printed.contains(item.amount) else { return nil }
            let category = item.category.flatMap { FinanceCategories.all.contains($0) ? $0 : nil } ?? "Uncategorised"
            return ReceiptLineItem(description: name, total: item.amount, category: category, confidence: 0.7)
        }
        let aiSum = aiItems.reduce(Decimal(0)) { $0 + $1.total }
        func parsedGap(_ total: Decimal) -> Decimal { parsed.items.isEmpty ? total : abs(parsed.splitTotal - total) }

        var total = parsedTotal ?? aiTotal ?? result.receiptTotal
        // Only use the model's items if none were dropped.
        if !aiItems.isEmpty, aiItems.count == ai.items.count {
            if needsHelp(parsed), let aiTotal, abs(aiSum - aiTotal) <= tolerance {
                // The model's items add up to a total printed on the receipt: the strongest answer.
                result.items = aiItems
                total = aiTotal
            } else if let current = total {
                if abs(aiSum - current) < parsedGap(current) { result.items = aiItems }
            } else if parsed.items.isEmpty {
                // No total anywhere: the model's items, all printed on the receipt, are the best guess.
                result.items = aiItems
            }
        }
        result.receiptTotal = total ?? (result.items.isEmpty ? nil : result.splitTotal)
        return result
    }

    /// Every money amount printed anywhere on the receipt, including discounts as positives.
    static func printedAmounts(in text: String) -> Set<Decimal> {
        guard let regex = try? NSRegularExpression(pattern: "\\d+(?:,\\d{3})*[.,]\\d{2}") else { return [] }
        let values = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Decimal? in
            guard let range = Range(match.range, in: text) else { return nil }
            return ReceiptParser.amountAtEnd(String(text[range]))
        }
        return Set(values)
    }

    private static func abs(_ value: Decimal) -> Decimal { value < 0 ? -value : value }
}
