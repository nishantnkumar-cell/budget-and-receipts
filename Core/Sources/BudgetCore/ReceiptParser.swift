import Foundation

/// An editable receipt draft. OCR fills it in, the person corrects it, and only then
/// does it become a `SplitDraft` for approval.
public struct ReceiptDraftEditor: Hashable, Sendable {
    public var merchant: String
    public var purchaseDate: Date?
    public var subtotal: Decimal?
    public var tax: Decimal?
    public var receiptTotal: Decimal?
    public var items: [ReceiptLineItem]
    public var rawText: String
    public var imagePath: String

    public var splitTotal: Decimal { items.reduce(0) { $0 + $1.total } }

    public init(
        merchant: String = "",
        purchaseDate: Date? = nil,
        subtotal: Decimal? = nil,
        tax: Decimal? = nil,
        receiptTotal: Decimal? = nil,
        items: [ReceiptLineItem] = [],
        rawText: String = "",
        imagePath: String = ""
    ) {
        self.merchant = merchant
        self.purchaseDate = purchaseDate
        self.subtotal = subtotal
        self.tax = tax
        self.receiptTotal = receiptTotal
        self.items = items
        self.rawText = rawText
        self.imagePath = imagePath
    }

    public mutating func addItem() {
        items.append(ReceiptLineItem(description: "New item", total: 0, confidence: 1))
    }

    public mutating func editItem(_ id: UUID, description: String? = nil, amount: Decimal? = nil, category: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let description { items[index].description = description }
        if let amount { items[index].total = amount }
        if let category { items[index].category = category }
    }

    /// Sets whose money one item is. Nil goes back to following the transaction.
    public mutating func setOwner(_ id: UUID, _ owner: MoneyOwner?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].owner = owner
    }

    public mutating func deleteItem(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    public func makeDraft(reviewed: Bool) -> SplitDraft {
        let receipt = ReceiptRecord(
            imagePath: imagePath,
            merchant: merchant,
            purchaseDate: purchaseDate,
            subtotal: subtotal,
            tax: tax,
            total: receiptTotal,
            rawText: rawText,
            items: items,
            confidence: 1,
            reviewed: reviewed
        )
        let splits = items.map { TransactionSplit(label: $0.description, category: $0.category, amount: $0.total, owner: $0.owner) }
        return SplitDraft(receipt: receipt, proposedSplits: splits)
    }
}

/// Turns OCR text lines into a first-guess receipt draft.
public enum ReceiptParser {
    public static func parse(_ lines: [String]) -> ReceiptDraftEditor {
        let money = lines.compactMap { line -> (String, Decimal)? in
            guard let amount = amountAtEnd(line) else { return nil }
            return (line, amount)
        }
        let total = money.last(where: { $0.0.range(of: "(?i)(grand total|amount due|total)", options: .regularExpression) != nil })?.1
            ?? money.last?.1
        let items = money.compactMap { line, amount -> ReceiptLineItem? in
            guard line.range(of: "(?i)(total|subtotal|vat|tax|cash|change|card)", options: .regularExpression) == nil else { return nil }
            let name = line
                .replacingOccurrences(of: "[£$€]?\\s*-?\\d+[.,]\\d{2}\\s*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : ReceiptLineItem(description: name, total: amount, confidence: 1)
        }
        return ReceiptDraftEditor(
            merchant: lines.first ?? "",
            receiptTotal: total,
            items: items,
            rawText: lines.joined(separator: "\n")
        )
    }

    public static func amountAtEnd(_ line: String) -> Decimal? {
        guard let range = line.range(of: "[£$€]?\\s*-?\\d+(?:,\\d{3})*[.,]\\d{2}\\s*$", options: .regularExpression) else { return nil }
        let value = String(line[range])
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Decimal(string: value)
    }
}
