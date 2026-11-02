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
        if dated.count >= 4 { return true }
        // Credit card statements whose text runs the transactions together.
        let pair = "\\d{1,2} [A-Za-z]{3} \\d{2,4} \\d{1,2} [A-Za-z]{3} \\d{2,4} "
        return lines.contains { $0.components(separatedBy: " ").count > 8 && ($0.range(of: pair, options: .regularExpression) != nil) }
    }

    public static func parse(_ lines: [String], fallbackYear: Int, timeZone: TimeZone = .current) throws -> [StatementRow] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let years = statementYears(lines, fallback: fallbackYear)
        let accountNumber = self.accountNumber(in: lines)
        let rows = cardColumns(lines, years: years, calendar: calendar, accountNumber: accountNumber)
            ?? table(lines, years: years, calendar: calendar, accountNumber: accountNumber)
        guard !rows.isEmpty else { throw StatementImportError.empty }
        return rows
    }

    /// The usual layout: date, details (sometimes over two or three lines), amount and often a
    /// running balance. Only lines between "brought forward" and "carried forward" count, when
    /// the statement has them, so summaries and small print are never read as payments.
    static func table(_ lines: [String], years: (start: Int, startMonth: Int, end: Int), calendar: Calendar, accountNumber: String?) -> [StatementRow] {
        let hasMarkers = lines.contains { $0.lowercased().contains("brought forward") }
        var inTable = !hasMarkers
        var expectBalance = false
        var rows: [StatementRow] = []
        var balance: Decimal?
        var date: Date?
        var parts: [String] = []
        /// Rows since the last balance, waiting for it to confirm their signs.
        var unconfirmed: [Int] = []

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            let values = amounts(in: line)
            let dated = leadingDate(line)
            if lower.contains("brought forward") || lower.contains("opening balance") || lower.contains("previous balance") {
                if lower.contains("brought forward") { inTable = true }
                if let last = values.last { balance = last.value } else { expectBalance = true }
                if let dated, let start = makeDate(dated, years: years, calendar: calendar) { date = start }
                parts = []
                continue
            }
            guard inTable else { continue }
            if expectBalance, let only = values.first, values.count == 1, dated == nil, descriptionText(line, dateLength: 0).isEmpty {
                balance = only.value
                expectBalance = false
                continue
            }
            if lower.contains("carried forward") || lower.contains("closing balance") {
                if hasMarkers { inTable = false }
                parts = []
                continue
            }
            if lower.hasPrefix("date ") || lower.hasPrefix("total") || line.count <= 2 { continue }
            var dateLength = dated?.length ?? 0
            if let dated, var day = makeDate(dated, years: years, calendar: calendar) {
                // Card statements give two dates, "received" then "transaction": use the second.
                let rest = String(line.dropFirst(dateLength)).trimmingCharacters(in: .whitespaces)
                if let second = leadingDate(rest), let transactionDay = makeDate(second, years: years, calendar: calendar) {
                    day = transactionDay
                    dateLength = line.count - rest.count + second.length
                }
                date = day
                parts = []
            }
            let text = descriptionText(line, dateLength: dateLength)
            guard !values.isEmpty else {
                if !text.isEmpty { parts.append(text) }
                // More than a couple of lines of words: the table has ended (small print, headers).
                if parts.count > 2 {
                    parts = []
                    date = nil
                }
                continue
            }
            guard let date else { continue }
            let description = (parts + [text]).filter { !$0.isEmpty }.joined(separator: " ")
            parts = []
            guard !description.isEmpty else { continue }

            let first = values[0]
            let credit = first.isCredit || isCreditWording(description.lowercased())
            rows.append(StatementRow(date: date, description: StatementImporter.cleanDescription(description), amount: credit ? first.value : -first.value, accountNumber: accountNumber))
            unconfirmed.append(rows.count - 1)
            if values.count >= 2 {
                // The running balance settles the signs: for one payment exactly, and for
                // several, it flips a lone guess that doesn't add up.
                let newBalance = values[values.count - 1].value
                if let previous = balance {
                    let change = newBalance - previous
                    if unconfirmed.count == 1, abs(change) == first.value {
                        rows[unconfirmed[0]].amount = change
                    } else {
                        let total = unconfirmed.reduce(Decimal(0)) { $0 + rows[$1].amount }
                        if total != change, let wrong = unconfirmed.first(where: { total - 2 * rows[$0].amount == change }) {
                            rows[wrong].amount = -rows[wrong].amount
                        }
                    }
                }
                balance = newBalance
                unconfirmed = []
            }
        }
        return rows
    }

    /// Credit card statements where the PDF text lists every transaction ("received" date,
    /// transaction date, details) run together, with the amounts in a column afterwards.
    /// The last transaction on a line sometimes carries its amount inline.
    static func cardColumns(_ lines: [String], years: (start: Int, startMonth: Int, end: Int), calendar: Calendar, accountNumber: String?) -> [StatementRow]? {
        let date = "(\\d{1,2} [A-Za-z]{3} \\d{2,4})"
        guard let pair = try? NSRegularExpression(pattern: "\(date) \(date) ") else { return nil }
        let detailLines = lines.filter { pair.numberOfMatches(in: $0, range: NSRange($0.startIndex..., in: $0)) >= 2 }
        guard !detailLines.isEmpty else { return nil }
        var queue = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: "^\\d{1,3}(?:,\\d{3})*\\.\\d{2}\\s?(?:CR|Cr)?$", options: .regularExpression) != nil
        }.compactMap { amounts(in: $0).first }

        var rows: [StatementRow] = []
        for line in detailLines {
            let matches = pair.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for (index, match) in matches.enumerated() {
                guard let dateRange = Range(match.range(at: 2), in: line),
                      let leading = leadingDate(String(line[dateRange])),
                      let day = makeDate(leading, years: years, calendar: calendar),
                      let start = Range(match.range, in: line)?.upperBound else { continue }
                let end = index + 1 < matches.count ? (Range(matches[index + 1].range, in: line)?.lowerBound ?? line.endIndex) : line.endIndex
                var details = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
                var amount: Amount?
                if index == matches.count - 1, let inline = amounts(in: details).last, details.hasSuffix(inline.text) {
                    amount = inline
                    details = String(details.dropLast(inline.text.count)).trimmingCharacters(in: .whitespaces)
                } else if !queue.isEmpty {
                    amount = queue.removeFirst()
                }
                guard let amount else { return nil }
                let credit = amount.isCredit || isCreditWording(details.lowercased())
                rows.append(StatementRow(date: day, description: StatementImporter.cleanDescription(details), amount: credit ? amount.value : -amount.value, accountNumber: accountNumber))
            }
        }
        // Every amount should have found its transaction; otherwise this isn't the layout.
        return queue.isEmpty ? rows : nil
    }

    /// Compares what was read with the statement's own summary ("Payments In" and "Payments
    /// Out", or a card's "Debits" and "Credits"). Returns the difference when they disagree,
    /// nil when they agree or the statement has no summary.
    public static func summaryDifference(_ lines: [String], rows: [StatementRow]) -> Decimal? {
        func total(_ labels: [String]) -> Decimal? {
            for line in lines.prefix(60) {
                let lower = line.lowercased().replacingOccurrences(of: " ", with: "")
                if labels.contains(where: { lower.hasPrefix($0) }), let value = amounts(in: line).last { return value.value }
            }
            return nil
        }
        let expected: Decimal
        if let paidIn = total(["paymentsin", "moneyin", "totalpaidin"]), let paidOut = total(["paymentsout", "moneyout", "totalpaidout"]) {
            expected = paidIn - paidOut
        } else if let debits = total(["debits"]), let credits = total(["credits"]) {
            expected = credits - debits
        } else {
            return nil
        }
        let read = rows.reduce(Decimal(0)) { $0 + $1.amount }
        return read == expected ? nil : read - expected
    }

    // MARK: Pieces

    struct Amount: Equatable {
        var value: Decimal
        var isCredit: Bool
        var text = ""
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
            return Amount(value: value < 0 ? -value : value, isCredit: credit, text: String(line[range]))
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
        // Bank codes: "CR" (credit) and "BGC" (bank giro credit) at the start of the details.
        if lower.hasPrefix("cr ") || lower.hasPrefix("bgc ") { return true }
        return ["salary", "payroll", "refund", "interest paid", "transfer from", "payment received", "thank you", "credit", "deposit", "paid in"]
            .contains(where: lower.contains)
    }

    /// "Account number 12345678", "Account No: 1234 5678" or a masked card "**** **** **** 1234".
    static func accountNumber(in lines: [String]) -> String? {
        let patterns = [
            "(?i)account\\s*(?:number|no\\.?)\\s*:?\\s*([0-9][0-9 ]{3,})",
            // UK sort code then account number, e.g. "40-25-02 12345678".
            "^\\d{2}-\\d{2}-\\d{2}\\s+(\\d{8})\\b",
            "(?:[*xX•]{4}[ -]?){2,}(\\d{4})\\b",
            // A full card number: only its last four digits are kept.
            "(?i)card number\\s*\\d{4} \\d{4} \\d{4} (\\d{4})\\b",
        ]
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
