import Foundation

public enum StatementFormat: String, CaseIterable, Sendable {
    case csv, ofx, qif

    /// Picks the format from a file name, e.g. "October.ofx". Defaults to CSV.
    public init(fileName: String) {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "ofx", "qfx": self = .ofx
        case "qif": self = .qif
        default: self = .csv
        }
    }
}

/// One line read from a bank statement, before it becomes a transaction.
public struct StatementRow: Hashable, Sendable {
    public var date: Date
    public var description: String
    public var amount: Decimal
    /// The bank's own id for the line (OFX FITID), when the file has one.
    public var bankID: String?
    /// The account number in the file (OFX ACCTID or a CSV account column), when there is one.
    public var accountNumber: String?

    public init(date: Date, description: String, amount: Decimal, bankID: String? = nil, accountNumber: String? = nil) {
        self.date = date
        self.description = description
        self.amount = amount
        self.bankID = bankID
        self.accountNumber = accountNumber
    }
}

public enum StatementImportError: Error, Equatable, Sendable {
    case empty
    case missingColumn(String)
    case badDate(line: Int, value: String)
    case badAmount(line: Int, value: String)
}

/// The order of day and month in dates such as 03/10/2026.
public enum DateOrder: String, CaseIterable, Sendable {
    /// 03/10/2026 is 3 October (UK and most of Europe).
    case dayMonthYear
    /// 03/10/2026 is 10 March (US).
    case monthDayYear
}

/// Which CSV columns hold what. Column numbers start at 0.
public struct CSVColumnMapping: Hashable, Sendable {
    public var date: Int
    public var description: Int
    /// A single signed amount column. Use this or `paidOut`/`paidIn`.
    public var amount: Int?
    public var paidOut: Int?
    public var paidIn: Int?
    public var hasHeader: Bool
    public var dateOrder: DateOrder
    /// True for amounts such as 12,50 (decimal comma).
    public var decimalComma: Bool
    /// A column with the account number, in files that hold several accounts.
    public var account: Int?

    public init(date: Int, description: Int, amount: Int? = nil, paidOut: Int? = nil, paidIn: Int? = nil, hasHeader: Bool = true, dateOrder: DateOrder = .dayMonthYear, decimalComma: Bool = false) {
        self.date = date
        self.description = description
        self.amount = amount
        self.paidOut = paidOut
        self.paidIn = paidIn
        self.hasHeader = hasHeader
        self.dateOrder = dateOrder
        self.decimalComma = decimalComma
        self.account = nil
    }

    /// Guesses the mapping from a header row such as "Date,Description,Amount" or
    /// "Date,Type,Details,Paid out,Paid in,Balance". Returns nil if it cannot.
    public static func guess(header: [String], dateOrder: DateOrder = .dayMonthYear) -> CSVColumnMapping? {
        let names = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func find(_ candidates: [String]) -> Int? {
            for candidate in candidates {
                if let index = names.firstIndex(where: { $0 == candidate }) { return index }
            }
            for candidate in candidates {
                if let index = names.firstIndex(where: { $0.contains(candidate) }) { return index }
            }
            return nil
        }
        guard let date = find(["date", "transaction date", "posted"]),
              let description = find(["description", "details", "narrative", "payee", "merchant", "memo", "name", "reference"]) else { return nil }
        let amount = find(["amount", "value"])
        let paidOut = find(["paid out", "money out", "debit", "withdrawal", "out"])
        let paidIn = find(["paid in", "money in", "credit", "deposit", "in"])
        guard amount != nil || (paidOut != nil && paidIn != nil) else { return nil }
        var mapping = CSVColumnMapping(date: date, description: description, amount: amount, paidOut: amount == nil ? paidOut : nil, paidIn: amount == nil ? paidIn : nil, dateOrder: dateOrder)
        mapping.account = names.firstIndex { ["account", "account number", "account no", "acct", "card number"].contains($0) }
        return mapping
    }
}

/// What an import would do: new transactions to add, and lines skipped or flagged.
public struct StatementImportResult: Hashable, Sendable {
    public var newTransactions: [BankTransaction]
    /// Lines already imported before (same fingerprint). They are skipped.
    public var duplicates: [StatementRow]
    /// New transactions that match an existing one on date and amount but not description,
    /// e.g. a manual entry. They are imported but should be checked.
    public var possibleDuplicates: [BankTransaction]
    /// For a PDF statement: how far what was read is from the statement's own totals. Nil when they agree.
    public var summaryDifference: Decimal? = nil
    /// Payments imported before their account was known, by fingerprint, with the account this
    /// statement shows they belong to. Importing gives them that account.
    public var accountForExisting: [String: UUID] = [:]
    /// The bank or card company named on the statement, for naming a new account.
    public var bankName: String? = nil
    /// The account holders named on the statement, for recognising payments to yourselves.
    public var holderNames: [String] = []
    /// Whose account the holders show it is (yours, your partner's or joint), matched against the
    /// names in Settings. Nil when the statement doesn't say or the names aren't set.
    public var holderOwner: MoneyOwner? = nil
}

public enum StatementImporter {
    // MARK: Parsing

    public static func parseCSV(_ text: String, mapping: CSVColumnMapping, timeZone: TimeZone = .current) throws -> [StatementRow] {
        var records = CSVReader.records(text).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        if mapping.hasHeader, !records.isEmpty { records.removeFirst() }
        guard !records.isEmpty else { throw StatementImportError.empty }
        let parser = DateParser(order: mapping.dateOrder, timeZone: timeZone)

        return try records.enumerated().map { offset, fields in
            let line = offset + (mapping.hasHeader ? 2 : 1)
            func field(_ index: Int?) -> String {
                guard let index, index < fields.count else { return "" }
                return fields[index].trimmingCharacters(in: .whitespaces)
            }
            let dateText = field(mapping.date)
            guard let date = parser.parse(dateText) else { throw StatementImportError.badDate(line: line, value: dateText) }

            let amount: Decimal
            if mapping.amount != nil {
                let text = field(mapping.amount)
                guard let value = AmountParser.parse(text, decimalComma: mapping.decimalComma) else { throw StatementImportError.badAmount(line: line, value: text) }
                amount = value
            } else {
                let outText = field(mapping.paidOut), inText = field(mapping.paidIn)
                let paidOut = outText.isEmpty ? 0 : AmountParser.parse(outText, decimalComma: mapping.decimalComma)
                let paidIn = inText.isEmpty ? 0 : AmountParser.parse(inText, decimalComma: mapping.decimalComma)
                guard let paidOut else { throw StatementImportError.badAmount(line: line, value: outText) }
                guard let paidIn else { throw StatementImportError.badAmount(line: line, value: inText) }
                amount = paidIn - abs(paidOut)
            }
            let account = field(mapping.account)
            return StatementRow(date: date, description: cleanDescription(field(mapping.description)), amount: amount, accountNumber: account.isEmpty ? nil : account)
        }
    }

    /// Reads the transactions in an OFX or QFX file (both the old SGML and the XML style).
    public static func parseOFX(_ text: String, timeZone: TimeZone = .current) throws -> [StatementRow] {
        let blocks = text.components(separatedBy: "<STMTTRN>").dropFirst()
        guard !blocks.isEmpty else { throw StatementImportError.empty }
        let accountNumber = ofxValue("ACCTID", in: text)
        return try blocks.enumerated().map { index, raw in
            let block = raw.components(separatedBy: "</STMTTRN>")[0]
            func tag(_ name: String) -> String? {
                guard let start = block.range(of: "<\(name)>") else { return nil }
                let rest = block[start.upperBound...]
                let end = rest.firstIndex(where: { $0 == "<" || $0 == "\n" || $0 == "\r" }) ?? rest.endIndex
                let value = rest[..<end].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            let dateText = tag("DTPOSTED") ?? ""
            guard let date = DateParser.parseOFX(dateText, timeZone: timeZone) else { throw StatementImportError.badDate(line: index + 1, value: dateText) }
            let amountText = tag("TRNAMT") ?? ""
            guard let amount = AmountParser.parse(amountText, decimalComma: false) else { throw StatementImportError.badAmount(line: index + 1, value: amountText) }
            let description = [tag("NAME"), tag("MEMO")].compactMap { $0 }.first ?? ""
            return StatementRow(date: date, description: cleanDescription(decodeEntities(description)), amount: amount, bankID: tag("FITID"), accountNumber: accountNumber)
        }
    }

    /// The first value of an OFX tag anywhere in the file, e.g. the account number.
    static func ofxValue(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(name)>") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.firstIndex(where: { $0 == "<" || $0 == "\n" || $0 == "\r" }) ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Reads a QIF file: D (date), T or U (amount), P (payee), M (memo), ^ (end of entry).
    public static func parseQIF(_ text: String, dateOrder: DateOrder = .dayMonthYear, timeZone: TimeZone = .current) throws -> [StatementRow] {
        let parser = DateParser(order: dateOrder, timeZone: timeZone)
        var rows: [StatementRow] = []
        var date: Date?, amount: Decimal?, payee = "", memo = ""
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let code = line.first else { continue }
            let value = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            switch code {
            case "D":
                guard let parsed = parser.parse(value.replacingOccurrences(of: "'", with: "/")) else { throw StatementImportError.badDate(line: offset + 1, value: value) }
                date = parsed
            case "T", "U":
                guard let parsed = AmountParser.parse(value, decimalComma: false) else { throw StatementImportError.badAmount(line: offset + 1, value: value) }
                amount = parsed
            case "P": payee = value
            case "M": memo = value
            case "^":
                if let date, let amount {
                    rows.append(StatementRow(date: date, description: cleanDescription(payee.isEmpty ? memo : payee), amount: amount))
                }
                date = nil; amount = nil; payee = ""; memo = ""
            default: continue
            }
        }
        guard !rows.isEmpty else { throw StatementImportError.empty }
        return rows
    }

    // MARK: Turning rows into transactions

    /// Builds transactions from statement lines and checks them against what is already
    /// stored. Importing the same file twice adds nothing the second time.
    ///
    /// Each line goes to the account whose number it carries (`accountForNumber`), else to
    /// `account`. With an account the fingerprint includes it, so the same coffee on the same
    /// day in two accounts is two payments; lines imported before accounts existed are still
    /// recognised as duplicates.
    public static func prepare(
        _ rows: [StatementRow],
        existing: [BankTransaction],
        account: UUID? = nil,
        accountForNumber: (String) -> UUID? = { _ in nil },
        calendar: Calendar = .current
    ) -> StatementImportResult {
        let existingIDs = Set(existing.map(\.fingerprint))
        // Lines imported before accounts were known keep their account-free fingerprint, even
        // after they're given an account: they still count, for that account (or no account).
        let legacyAccounts = Dictionary(existing.filter { !$0.fingerprint.contains("|acct:") }.map { ($0.fingerprint, $0.accountID) }, uniquingKeysWith: { first, _ in first })
        var seenInFile: [String: Int] = [:]
        var result = StatementImportResult(newTransactions: [], duplicates: [], possibleDuplicates: [])

        for row in rows {
            let rowAccount = row.accountNumber.flatMap(accountForNumber) ?? account
            let base = baseFingerprint(row, calendar: calendar)
            let key = rowAccount.map { "\(base)|acct:\($0.uuidString)" } ?? base
            let occurrence = seenInFile[key, default: 0] + 1
            seenInFile[key] = occurrence
            // Two identical lines in one file (two coffees on the same day) are both real.
            let legacy = row.bankID.map { "ofx:\($0)" } ?? "\(base)|\(occurrence)"
            let fingerprint: String
            if let rowAccount {
                fingerprint = row.bankID.map { "ofx:\(rowAccount.uuidString):\($0)" } ?? "\(key)|\(occurrence)"
            } else {
                fingerprint = legacy
            }
            let legacyMatch = legacyAccounts[legacy].map { $0 == nil || $0 == rowAccount } ?? false
            if existingIDs.contains(fingerprint) || legacyMatch {
                result.duplicates.append(row)
                if let rowAccount, legacyMatch, legacyAccounts[legacy] == .some(nil) { result.accountForExisting[legacy] = rowAccount }
                continue
            }
            var transaction = BankTransaction(date: row.date, merchant: row.description, description: row.description, amount: row.amount, fingerprint: fingerprint)
            transaction.accountID = rowAccount
            result.newTransactions.append(transaction)
            if existing.contains(where: { $0.amount == row.amount && calendar.isDate($0.date, inSameDayAs: row.date) && ($0.accountID == nil || $0.accountID == rowAccount) }) {
                result.possibleDuplicates.append(transaction)
            }
        }
        return result
    }

    /// A readable, stable key for a statement line: date, amount and description.
    /// Kept simple on purpose so the Windows app can compute exactly the same value.
    public static func baseFingerprint(_ row: StatementRow, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: row.date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "stmt:\(day)|\(row.amount)|\(row.description.uppercased())"
    }

    public static func cleanDescription(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

/// Splits CSV text into records, handling quoted fields with commas, quotes and line breaks.
public enum CSVReader {
    /// The header row, or an empty array for an empty file.
    public static func firstRecord(_ text: String) -> [String] {
        records(text).first ?? []
    }

    public static func records(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        while let char = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }
            switch char {
            case "\"": inQuotes = true
            case ",": record.append(field); field = ""
            case "\n", "\r\n", "\r":
                record.append(field); field = ""
                records.append(record); record = []
            case "\u{FEFF}": continue
            default: field.append(char)
            }
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}

/// Parses money such as "£1,234.56", "-12.50", "(12.50)", "12.50 DR" or "12,50" (decimal comma).
public enum AmountParser {
    public static func parse(_ text: String, decimalComma: Bool) -> Decimal? {
        var value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        var negative = false
        if value.hasPrefix("(") && value.hasSuffix(")") {
            negative = true
            value = String(value.dropFirst().dropLast())
        }
        let upper = value.uppercased()
        if upper.hasSuffix("DR") { negative = true; value = String(value.dropLast(2)) }
        else if upper.hasSuffix("CR") { value = String(value.dropLast(2)) }
        value = value.replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        if decimalComma {
            value = value.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else {
            value = value.replacingOccurrences(of: ",", with: "")
        }
        if value.hasPrefix("+") { value.removeFirst() }
        if value.hasPrefix("-") { negative.toggle(); value.removeFirst() }
        // ASCII digits only: "½", "²" or other scripts' digits are not amounts.
        guard !value.isEmpty, value.allSatisfy({ ("0"..."9").contains($0) || $0 == "." }), value.filter({ $0 == "." }).count <= 1,
              let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -number : number
    }
}

/// Parses statement dates. Dates are set to midday so a time-zone change never moves them to another day.
struct DateParser {
    let order: DateOrder
    let timeZone: TimeZone

    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    func parse(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." || $0 == " " })
            .map(String.init)
        guard parts.count == 3 else { return nil }
        var year: Int?, month: Int?, day: Int?
        if parts[0].count == 4 {
            year = Int(parts[0]); month = Int(parts[1]); day = Int(parts[2])
        } else if let named = Self.monthNames.firstIndex(of: String(parts[1].prefix(3)).lowercased()) {
            day = Int(parts[0]); month = named + 1; year = Int(parts[2])
        } else {
            let first = Int(parts[0]), second = Int(parts[1])
            (day, month) = order == .dayMonthYear ? (first, second) : (second, first)
            year = Int(parts[2])
        }
        guard var year, let month, let day else { return nil }
        if year < 100 { year += 2000 }
        return Self.makeDate(year: year, month: month, day: day, timeZone: timeZone)
    }

    /// OFX dates start with YYYYMMDD, e.g. 20261003120000[0:GMT].
    static func parseOFX(_ text: String, timeZone: TimeZone) -> Date? {
        let digits = text.prefix(8)
        guard digits.count == 8, digits.allSatisfy(\.isNumber),
              let year = Int(digits.prefix(4)), let month = Int(digits.dropFirst(4).prefix(2)), let day = Int(digits.suffix(2)) else { return nil }
        return makeDate(year: year, month: month, day: day, timeZone: timeZone)
    }

    static func makeDate(year: Int, month: Int, day: Int, timeZone: TimeZone) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
        return date
    }
}
