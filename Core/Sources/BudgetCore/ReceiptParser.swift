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

/// Turns OCR text lines into a first-guess receipt draft. Everything it finds stays
/// editable: the person checks it before anything is approved.
public enum ReceiptParser {
    public static func parse(_ lines: [String], calendar: Calendar = .current) -> ReceiptDraftEditor {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var items: [ReceiptLineItem] = []
        var total: Decimal?
        var subtotal: Decimal?
        var tax: Decimal?

        for line in lines {
            guard let amount = amountAtEnd(line) else { continue }
            let name = label(of: line)
            if matches(name, subtotalPattern) {
                subtotal = amount
            } else if matches(name, totalPattern) {
                total = amount
            } else if matches(name, taxPattern) {
                tax = amount
            } else if matches(name, paymentPattern) || name.isEmpty {
                continue
            } else if amount < 0 || matches(name, discountPattern) {
                // A discount line takes money off the item above it.
                guard let last = items.indices.last else { continue }
                items[last].total = max(0, items[last].total - abs(amount))
            } else {
                items.append(ReceiptLineItem(description: name, total: amount, confidence: 0.8))
            }
        }
        return ReceiptDraftEditor(
            merchant: merchant(in: lines),
            purchaseDate: lines.lazy.compactMap { date(in: $0, calendar: calendar) }.first,
            subtotal: subtotal,
            tax: tax,
            receiptTotal: total ?? items.last.map { _ in items.reduce(0) { $0 + $1.total } },
            items: items,
            rawText: lines.joined(separator: "\n")
        )
    }

    /// The money amount at the end of a line, if any. Handles "£1.20", "1,234.50",
    /// "-0.50", "0.50-" (a till's way of writing a discount) and a VAT code after the amount ("1.20 A").
    public static func amountAtEnd(_ line: String) -> Decimal? {
        let pattern = "(-)?\\s*[£$€]?\\s*(\\d+(?:,\\d{3})*[.,]\\d{2})(-)?(?:\\s+[A-Z*])?\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let numberRange = Range(match.range(at: 2), in: line) else { return nil }
        var number = String(line[numberRange])
        // "12,50" is a decimal comma; "1,234.50" has a thousands comma.
        if number.range(of: "^\\d+,\\d{2}$", options: .regularExpression) != nil {
            number = number.replacingOccurrences(of: ",", with: ".")
        } else {
            number = number.replacingOccurrences(of: ",", with: "")
        }
        guard let value = Decimal(string: number) else { return nil }
        let negative = match.range(at: 1).location != NSNotFound || match.range(at: 3).location != NSNotFound
        return negative ? -value : value
    }

    // MARK: Pieces

    static let subtotalPattern = "(?i)\\bsub[- ]?total\\b"
    static let totalPattern = "(?i)(\\btotal\\b|amount due|balance due|to pay)"
    static let taxPattern = "(?i)\\b(vat|tax)\\b"
    static let paymentPattern = "(?i)(^(cash|change|card|visa|mastercard|amex|contactless|debit|credit|paid)\\b|\\b(tendered|change due|card payment)\\b)"
    static let discountPattern = "(?i)\\b(discount|saving|savings|promo|offer|clubcard price|nectar price|reduced|multibuy)\\b"

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The line without its amount, VAT code or a leading quantity like "2 x".
    static func label(of line: String) -> String {
        line.replacingOccurrences(of: "-?\\s*[£$€]?\\s*\\d+(?:,\\d{3})*[.,]\\d{2}-?(?:\\s+[A-Z*])?\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+\\d+\\s*[x@]\\s*[£$€]?\\d+[.,]\\d{2}\\s*$", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// The shop name: the first line with letters that is not a greeting, address or amount.
    static func merchant(in lines: [String]) -> String {
        let skip = "(?i)(welcome|receipt|thank|tel|phone|www\\.|vat no|vat reg|^\\d)"
        return lines.first { line in
            line.contains(where: \.isLetter) && amountAtEnd(line) == nil && !matches(line, skip)
        } ?? lines.first ?? ""
    }

    /// A UK-style date: 12/10/2026, 12-10-26, 12.10.2026 or 12 Oct 2026. Day comes first.
    static func date(in line: String, calendar: Calendar) -> Date? {
        let numeric = "\\b(\\d{1,2})[/.-](\\d{1,2})[/.-](\\d{2}|\\d{4})\\b"
        let named = "(?i)\\b(\\d{1,2})\\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\s+(\\d{2}|\\d{4})\\b"
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        for (pattern, isNamed) in [(numeric, false), (named, true)] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let dayRange = Range(match.range(at: 1), in: line),
                  let monthRange = Range(match.range(at: 2), in: line),
                  let yearRange = Range(match.range(at: 3), in: line),
                  let day = Int(line[dayRange]), var year = Int(line[yearRange]) else { continue }
            let monthText = line[monthRange].lowercased()
            guard let month = isNamed ? months.firstIndex(of: String(monthText.prefix(3))).map({ $0 + 1 }) : Int(monthText) else { continue }
            if year < 100 { year += 2000 }
            guard (1...12).contains(month), (1...31).contains(day) else { continue }
            var parts = DateComponents(year: year, month: month, day: day, hour: 12)
            parts.calendar = calendar
            if let date = calendar.date(from: parts), calendar.component(.day, from: date) == day { return date }
        }
        return nil
    }
}
