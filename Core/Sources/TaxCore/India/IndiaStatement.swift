import BudgetCore
import Foundation

public enum IndiaStatementError: Error, Equatable, Sendable {
    /// An Excel, PDF or web page file, which has to be saved as CSV first.
    case notText(String)
    case noHeader
    case empty
    case badDate(line: Int, value: String)
    case badAmount(line: Int, value: String)

    public var explanation: String {
        switch self {
        case .notText(let kind):
            "This is \(kind). Open it in Numbers or Excel, export it as CSV, and choose that file. If it asks for a password, your bank's message about the statement says what it is."
        case .noHeader:
            "No row with date, withdrawal and deposit (or debit and credit) columns was found. Choose the account statement downloaded from your bank, saved as CSV."
        case .empty: "The file has column names but no payments."
        case .badDate(let line, let value): "Line \(line) has a date that couldn't be read: “\(value)”. Nothing was imported."
        case .badAmount(let line, let value): "Line \(line) has an amount that couldn't be read: “\(value)”. Nothing was imported."
        }
    }
}

/// A rupee statement downloaded as text: comma or tab separated, with any heading lines above
/// the column names, as ICICI and SBI files have. Columns are found by their names.
public struct IndiaStatement: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        public var date: Date
        public var narration: String
        public var amount: Decimal
        public var balance: Decimal?
    }

    public var lines: [Line]
    /// The last four digits of the account number, when a heading gives it.
    public var lastFour: String?
    /// How far the payments are from the change in the running balance, which means a line is
    /// missing or misread. Nil when they agree or there's no balance.
    public var balanceDifference: Decimal?

    /// Checks what kind of file it is before reading it as text.
    public static func read(_ data: Data) throws -> IndiaStatement {
        let start = [UInt8](data.prefix(8))
        if start.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw IndiaStatementError.notText("an Excel file") }
        if start.starts(with: [0x50, 0x4B, 0x03, 0x04]) { throw IndiaStatementError.notText("an Excel or compressed file") }
        if start.starts(with: Array("%PDF".utf8)) { throw IndiaStatementError.notText("a PDF") }
        let text: String
        if start.starts(with: [0xFF, 0xFE]) || start.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16) ?? ""
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        if text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).first == "<" { throw IndiaStatementError.notText("a web page saved as a spreadsheet") }
        return try read(text: text)
    }

    private struct Columns {
        var date: Int
        var narration: Int
        var withdrawal: Int
        var deposit: Int
        var balance: Int?
    }

    private static func name(_ cell: String) -> String {
        // "Withdrawal Amount (INR )" and "Debit(₹)" are read as "withdrawal amount" and "debit".
        let outsideBrackets = cell.lowercased().replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        return outsideBrackets.split { !$0.isLetter }.joined(separator: " ")
    }

    private static func columns(_ record: [String]) -> Columns? {
        let names = record.map(name)
        func find(_ candidates: [String]) -> Int? {
            for candidate in candidates {
                if let index = names.firstIndex(of: candidate) { return index }
            }
            return nil
        }
        // The day the money moved; the value date only when there is no other.
        guard let date = find(["transaction date", "txn date", "tran date", "date", "value date"]),
              let narration = find(["transaction remarks", "description", "details", "narration", "particulars", "remarks"]),
              let withdrawal = find(["withdrawal amount", "withdrawal amt", "withdrawal", "withdrawals", "debit", "debit amount"]),
              let deposit = find(["deposit amount", "deposit amt", "deposit", "deposits", "credit", "credit amount"]) else { return nil }
        return Columns(date: date, narration: narration, withdrawal: withdrawal, deposit: deposit,
                       balance: find(["balance", "balance amount", "closing balance", "running balance"]))
    }

    private static func records(_ text: String) -> [[String]] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let tabbed = lines.contains { $0.contains("\t") && columns($0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)) != nil }
        if tabbed { return lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) } }
        return CSVReader.records(text)
    }

    public static func read(text: String) throws -> IndiaStatement {
        let records = records(text)
        guard let header = records.firstIndex(where: { columns($0) != nil }), let found = columns(records[header]) else {
            throw IndiaStatementError.noHeader
        }
        let parser = DateParser(order: .dayMonthYear, timeZone: TaxYear.calendar.timeZone)
        var lines: [Line] = []

        for (index, record) in records.enumerated().dropFirst(header + 1) {
            func field(_ column: Int?) -> String {
                guard let column, column < record.count else { return "" }
                return record[column].trimmingCharacters(in: .whitespaces)
            }
            let whole = record.joined(separator: " ").lowercased()
            if columns(record) != nil { continue }
            let dateText = field(found.date)
            let outText = field(found.withdrawal), inText = field(found.deposit)
            let hasMoney = (outText + inText).contains { $0.isNumber && $0 != "0" }
            guard let date = parser.parse(dateText) else {
                // A second table after the payments, as some SBI files have for cheques. It
                // starts with its heading in the first or date column, on a line with no money,
                // so a payment's wording (even wrapped onto its own line) never ends the file.
                let headings = [field(0), dateText].map { $0.lowercased() }
                if !hasMoney && headings.contains(where: { $0.hasPrefix("cheque status") || $0.hasPrefix("legends") }) { break }
                // Totals and notes under the payments have no date. A line with money and a
                // date that can't be read must never be dropped quietly.
                let isTotal = !dateText.contains(where: \.isNumber) && (whole.contains("total") || whole.contains("balance"))
                if hasMoney && !isTotal { throw IndiaStatementError.badDate(line: index + 1, value: dateText) }
                continue
            }
            func rupees(_ text: String) throws -> Decimal {
                if text.isEmpty || text == "-" || text == "--" { return 0 }
                guard let value = amount(text) else { throw IndiaStatementError.badAmount(line: index + 1, value: text) }
                return value
            }
            let out = abs(try rupees(outText)), into = abs(try rupees(inText))
            if out == 0 && into == 0 { continue }
            if out != 0 && into != 0 { throw IndiaStatementError.badAmount(line: index + 1, value: "\(outText) and \(inText)") }
            let balanceText = field(found.balance)
            let balance = balanceText.isEmpty || balanceText == "-" ? nil : try rupees(balanceText)
            lines.append(Line(date: date, narration: StatementImporter.cleanDescription(field(found.narration)),
                              amount: into - out, balance: balance))
        }
        guard !lines.isEmpty else { throw IndiaStatementError.empty }
        let rows = lines.map { StatementRow(date: $0.date, description: $0.narration, amount: $0.amount, balance: $0.balance) }
        return IndiaStatement(lines: lines, lastFour: accountEnding(records.prefix(header)),
                              balanceDifference: StatementImporter.balanceDifference(rows))
    }

    private static func amount(_ text: String) -> Decimal? {
        var value = text.uppercased()
        for symbol in ["INR", "₹", "RS."] { value = value.replacingOccurrences(of: symbol, with: "") }
        return AmountParser.parse(value, decimalComma: false)
    }

    /// The digits after a heading such as "Account Number", in the same cell or a later one.
    private static func accountEnding(_ headings: ArraySlice<[String]>) -> String? {
        for record in headings {
            guard let at = record.firstIndex(where: {
                let name = name($0)
                return name.contains("account number") || name.contains("account no") || name.hasPrefix("transactions list")
            }) else { continue }
            for cell in record[at...] {
                // The last long run of digits, so a masked number "XXXXXXXX1234" works too.
                if let run = cell.split(whereSeparator: { !$0.isNumber }).last(where: { $0.count >= 4 }) {
                    return String(run.suffix(4))
                }
            }
        }
        return nil
    }

    /// The lines as entries of one account, split into new ones and ones already there.
    /// Importing the same or an overlapping statement again adds nothing twice.
    public func entries(for accountID: String, existing: [IndiaEntry]) -> (new: [IndiaEntry], alreadyThere: Int) {
        func dayText(_ date: Date) -> String {
            let day = TaxYear.calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        }
        // Lines already imported, by day and amount. Each stands for at most one line here.
        var held = Dictionary(grouping: existing.filter { $0.accountID == accountID && !$0.isManual }) {
            "\(dayText($0.date))|\($0.amount)"
        }
        var taken = Set(existing.map(\.id))
        var found = Set<Int>()
        // The same running balance means the same line, however the bank words it. These are
        // matched first, so a line without a balance can't claim one of them.
        for (index, line) in lines.enumerated() where line.balance != nil {
            let slot = "\(dayText(line.date))|\(line.amount)"
            if let match = held[slot]?.firstIndex(where: { $0.balance == line.balance }) {
                held[slot]?.remove(at: match)
                found.insert(index)
            }
        }
        // One of the two files has no balance column: the wording has to do.
        for (index, line) in lines.enumerated() where !found.contains(index) {
            let slot = "\(dayText(line.date))|\(line.amount)"
            if let match = held[slot]?.firstIndex(where: {
                (line.balance == nil || $0.balance == nil) && $0.narration.caseInsensitiveCompare(line.narration) == .orderedSame
            }) {
                held[slot]?.remove(at: match)
                found.insert(index)
            }
        }
        var new: [IndiaEntry] = []
        for (index, line) in lines.enumerated() where !found.contains(index) {
            let mark = line.balance.map { "b\($0)" } ?? line.narration.uppercased()
            let key = "\(accountID)|\(dayText(line.date))|\(line.amount)|\(mark)"
            var occurrence = 1
            while taken.contains("\(key)|\(occurrence)") { occurrence += 1 }
            let id = "\(key)|\(occurrence)"
            taken.insert(id)
            new.append(IndiaEntry(id: id, accountID: accountID, date: line.date, narration: line.narration,
                                  amount: line.amount, balance: line.balance))
        }
        return (new, found.count)
    }
}
