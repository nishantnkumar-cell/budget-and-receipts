import Foundation

/// Reads bank and credit card statements from the text of a PDF (as PDFKit extracts it).
/// Banks lay statements out differently, so this looks for what they share: lines that
/// start with a date and end with amounts, usually "paid out or paid in, then balance".
/// When there is a running balance, its change gives the sign of each payment exactly.
public enum PDFStatementParser {
    /// True when the text looks like a statement rather than a receipt: several dated lines
    /// with amounts, and statement wording such as "balance" or "account number".
    public static func looksLikeStatement(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: "\n").lowercased()
        let wording = ["statement", "balance", "account number", "sort code", "brought forward", "paid out", "money out"]
        guard wording.contains(where: text.contains) else { return false }
        let dated = lines.filter { leadingDate($0) != nil && !amounts(in: $0).isEmpty }
        return dated.count >= 4
    }

    public static func parse(_ lines: [String], fallbackYear: Int, timeZone: TimeZone = .current) throws -> [StatementRow] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let years = statementYears(lines, fallback: fallbackYear)
        let accountNumber = self.accountNumber(in: lines)
        var rows: [StatementRow] = []
        var balance: Decimal?
        var lastDate: Date?

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            let values = amounts(in: line)
            if lower.contains("brought forward") || lower.contains("opening balance") || lower.contains("previous balance") || lower.contains("balance from previous") {
                if let last = values.last { balance = last.value }
                continue
            }
            if lower.contains("carried forward") || lower.contains("closing balance") || lower.hasPrefix("total") || lower.contains("new balance") { continue }

            let dated = leadingDate(line)
            guard !values.isEmpty, let date = dated.flatMap({ makeDate($0, years: years, calendar: calendar) }) ?? lastDate else { continue }
            lastDate = date
            let description = descriptionText(line, dateLength: dated?.length ?? 0)
            guard !description.isEmpty else { continue }

            var amount = values[0].value
            if values.count >= 2 {
                // Amount then running balance.
                let newBalance = values[values.count - 1].value
                if let previous = balance, abs(newBalance - previous) == amount {
                    amount = newBalance - previous
                } else {
                    amount = values[0].isCredit || isCreditWording(lower) ? amount : -amount
                }
                balance = newBalance
            } else {
                // No balance column, e.g. a credit card: spending unless marked as a credit.
                amount = values[0].isCredit || isCreditWording(lower) ? amount : -amount
            }
            rows.append(StatementRow(date: date, description: StatementImporter.cleanDescription(description), amount: amount, accountNumber: accountNumber))
        }
        guard !rows.isEmpty else { throw StatementImportError.empty }
        return rows
    }

    // MARK: Pieces

    struct Amount: Equatable {
        var value: Decimal
        var isCredit: Bool
    }

    /// Money amounts in a line, left to right. "12.40CR" or "12.40 CR" is a credit.
    static func amounts(in line: String) -> [Amount] {
        let pattern = "(?<![\\d.,])-?[£$€]?\\d{1,3}(?:,\\d{3})*\\.\\d{2}(?:\\s?(CR|DR|Cr|Dr))?(?![\\d])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range, in: line) else { return nil }
            var text = String(line[range])
            let credit = text.uppercased().hasSuffix("CR")
            text = text.replacingOccurrences(of: "(?i)\\s?(CR|DR)$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[£$€,]", with: "", options: .regularExpression)
            guard let value = Decimal(string: text) else { return nil }
            return Amount(value: value < 0 ? -value : value, isCredit: credit)
        }
    }

    struct LeadingDate {
        var day: Int
        var month: Int
        var year: Int?
        var length: Int
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// A date at the start of a line: "03 Oct", "3 October 2026", "03/10/2026", "03-10-26".
    static func leadingDate(_ line: String) -> LeadingDate? {
        let named = "^(\\d{1,2})\\s+([A-Za-z]{3,9})\\.?(?:\\s+(\\d{4}|\\d{2}))?\\b"
        let numeric = "^(\\d{1,2})[/.-](\\d{1,2})(?:[/.-](\\d{4}|\\d{2}))?\\b"
        for (pattern, isNamed) in [(named, true), (numeric, false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let dayRange = Range(match.range(at: 1), in: line),
                  let monthRange = Range(match.range(at: 2), in: line),
                  let day = Int(line[dayRange]) else { continue }
            let monthText = line[monthRange].lowercased()
            let month = isNamed ? months.firstIndex(of: String(monthText.prefix(3))).map { $0 + 1 } : Int(monthText)
            guard let month, (1...12).contains(month), (1...31).contains(day) else { continue }
            if isNamed, monthText.count > 3, !["january", "february", "march", "april", "june", "july", "august", "september", "october", "november", "december", "sept"].contains(monthText) { continue }
            var year = Range(match.range(at: 3), in: line).flatMap { Int(line[$0]) }
            if let short = year, short < 100 { year = 2000 + short }
            return LeadingDate(day: day, month: month, year: year, length: match.range.length)
        }
        return nil
    }

    /// The statement's year or years, from wording such as "1 December 2025 to 31 January 2026".
    static func statementYears(_ lines: [String], fallback: Int) -> (start: Int, startMonth: Int, end: Int) {
        let pattern = "(?i)\\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\.?\\s+(20\\d{2})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (fallback, 1, fallback) }
        for line in lines.prefix(40) {
            let found = regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match -> (Int, Int)? in
                guard let m = Range(match.range(at: 1), in: line), let y = Range(match.range(at: 2), in: line),
                      let month = months.firstIndex(of: line[m].lowercased()), let year = Int(line[y]) else { return nil }
                return (month + 1, year)
            }
            if found.count >= 2 { return (found[0].1, found[0].0, found[found.count - 1].1) }
            if let only = found.first { return (only.1, 1, only.1) }
        }
        return (fallback, 1, fallback)
    }

    static func makeDate(_ date: LeadingDate, years: (start: Int, startMonth: Int, end: Int), calendar: Calendar) -> Date? {
        let year = date.year ?? (years.start != years.end && date.month < years.startMonth ? years.end : years.start)
        let parts = DateComponents(year: year, month: date.month, day: date.day, hour: 12)
        guard let result = calendar.date(from: parts), calendar.component(.day, from: result) == date.day else { return nil }
        return result
    }

    /// The text between the date and the first amount.
    static func descriptionText(_ line: String, dateLength: Int) -> String {
        let rest = String(line.dropFirst(dateLength))
        let cut = rest.range(of: "-?[£$€]?\\d{1,3}(?:,\\d{3})*\\.\\d{2}", options: .regularExpression)?.lowerBound ?? rest.endIndex
        return String(rest[..<cut]).trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
    }

    static func isCreditWording(_ lower: String) -> Bool {
        ["salary", "payroll", "refund", "interest paid", "transfer from", "payment received", "thank you", "credit", "deposit", "paid in"]
            .contains(where: lower.contains)
    }

    /// "Account number 12345678", "Account No: 1234 5678" or a masked card "**** **** **** 1234".
    static func accountNumber(in lines: [String]) -> String? {
        let patterns = ["(?i)account\\s*(?:number|no\\.?)\\s*:?\\s*([0-9][0-9 ]{3,})", "(?:[*xX•]{4}[ -]?){2,}(\\d{4})\\b"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for line in lines.prefix(60) {
                if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let range = Range(match.range(at: 1), in: line) {
                    let digits = line[range].filter(\.isNumber)
                    if digits.count >= 4 { return String(digits) }
                }
            }
        }
        return nil
    }

    private static func abs(_ value: Decimal) -> Decimal { value < 0 ? -value : value }
}
