import BudgetCore
import Foundation

/// A document that has a place of its own, and mustn't be read as a bank statement.
public enum TaxDocument: Sendable {
    case lettingStatement, payslip

    public static func recognise(_ text: String) -> TaxDocument? {
        if UploadText.contains(text, "PAYE Net Pay") && UploadText.contains(text, "Total Taxable Pay") { return .payslip }
        if UploadText.contains(text, "Remittance Advice") && UploadText.contains(text, "Rent receipt") { return .lettingStatement }
        if UploadText.contains(text, "Management Statement") && UploadText.contains(text, "Rent received this statement") { return .lettingStatement }
        return nil
    }

    /// Where it belongs, for a message when it's offered as a bank statement.
    public var explanation: String {
        switch self {
        case .lettingStatement: "This is a letting agent's statement. Import it under Property & Tax › Pay and Statements."
        case .payslip: "This is a payslip. Import it under Property & Tax › Pay and Statements."
        }
    }
}

/// Small helpers for reading figures out of a document's text.
enum UploadText {
    /// A pound amount, capturing the figure.
    static let amount = #"£\s*((?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})"#
    /// A day written 05/06/2026 or 05.06.2026, capturing all of it.
    static let date = #"(\d{2}[./]\d{2}[./]\d{4})"#

    static func contains(_ text: String, _ phrase: String) -> Bool {
        first(phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#), in: text) != nil
    }

    struct Match {
        var groups: [String]
        var range: Range<String.Index>
    }

    static func all(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { found in
            guard let range = Range(found.range, in: text) else { return nil }
            let groups = (1..<max(found.numberOfRanges, 1)).map { Range(found.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            return Match(groups: groups, range: range)
        }
    }

    static func first(_ pattern: String, in text: String) -> Match? { all(pattern, in: text).first }

    static func money(_ text: String) -> Decimal? {
        Decimal(string: text.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The amount after a label.
    static func amount(after label: String, in text: String) -> Decimal? {
        first(label + #"\s*:?\s*"# + amount, in: text).flatMap { money($0.groups[0]) }
    }

    /// Noon in London on a day written day first, so it's the same day everywhere.
    static func day(_ text: String) -> Date? {
        DateParser(order: .dayMonthYear, timeZone: TaxYear.calendar.timeZone).parse(text)
    }
}
