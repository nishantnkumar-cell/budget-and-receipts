import BudgetCore
import Foundation

/// One letting agent statement read from a file: the gross rent and what the agent kept.
public struct LettingStatement: Hashable, Sendable {
    public var date: Date
    public var grossRent: Decimal
    public var fees: Decimal
    public var repairs: Decimal
    public var otherExpense: Decimal
    /// The statement's own number or reference, when it has one.
    public var reference: String
    /// The property as the file names it (spreadsheet files only).
    public var propertyName: String?
    /// True when the figures were checked against the amount the document says was paid.
    public var isChecked: Bool
    /// What to compare with the document before relying on it.
    public var warnings: [String]
    /// True when something is wrong enough that it shouldn't be imported without looking.
    public var needsAttention: Bool

    public init(date: Date, grossRent: Decimal, fees: Decimal = 0, repairs: Decimal = 0, otherExpense: Decimal = 0,
                reference: String = "", propertyName: String? = nil, isChecked: Bool = false, warnings: [String] = [],
                needsAttention: Bool = false) {
        self.date = date
        self.grossRent = grossRent
        self.fees = fees
        self.repairs = repairs
        self.otherExpense = otherExpense
        self.reference = reference
        self.propertyName = propertyName
        self.isChecked = isChecked
        self.warnings = warnings
        self.needsAttention = needsAttention
    }

    public var paidToYou: Decimal { grossRent - fees - repairs - otherExpense }
}

public enum LettingStatementError: Error, Equatable, Sendable {
    case notRecognised
    case missing(String)

    public var explanation: String {
        switch self {
        case .notRecognised:
            "This file isn't a layout the app knows: a PDF headed “Remittance Advice” or “Management Statement”, or a CSV of property, gross rent, fee, deductions, net and date. Nothing was imported; add the statement by hand."
        case .missing(let what): "The \(what) couldn't be found in this statement. Nothing was imported; add it by hand."
        }
    }
}

public enum LettingStatementReader {
    /// Reads a PDF statement from its text. Pass each way of taking the text out of the file
    /// (they order table cells differently); the reading that checks out best is used.
    public static func read(texts: [String]) throws -> LettingStatement {
        var best: LettingStatement?
        var failure = LettingStatementError.notRecognised
        for text in texts {
            do {
                let found = try read(text: text)
                if best.map({ score(found) > score($0) }) ?? true { best = found }
            } catch let error as LettingStatementError {
                if error != .notRecognised { failure = error }
            }
        }
        if let best { return best }
        throw failure
    }

    private static func score(_ statement: LettingStatement) -> Int {
        (statement.isChecked ? 100 : 0) + (statement.needsAttention ? 0 : 50) - statement.warnings.count
    }

    static func read(text: String) throws -> LettingStatement {
        guard TaxDocument.recognise(text) == .lettingStatement else { throw LettingStatementError.notRecognised }
        return UploadText.contains(text, "Remittance Advice") ? try remittance(text) : try management(text)
    }

    private static func remittance(_ text: String) throws -> LettingStatement {
        let amount = UploadText.amount, date = UploadText.date
        // Rent for each period listed; the same line repeated on a later page counts once.
        var seen = Set<String>()
        var rent: Decimal = 0
        var periodStart: Date?
        for match in UploadText.all(#"Rent receipt\s+"# + date + #"\s*[-–]\s*"# + date + #"\s+"# + amount, in: text) {
            guard seen.insert(match.groups.joined(separator: "|")).inserted, let value = UploadText.money(match.groups[2]) else { continue }
            rent += value
            periodStart = periodStart ?? UploadText.day(match.groups[0])
        }
        guard rent > 0 else { throw LettingStatementError.missing("rent received") }

        var warnings: [String] = []
        let paid = UploadText.first(#"Paid\s+"# + amount + #"\s+via\s+Bank\s+Transfer\s+on\s+"# + date, in: text)
        let paidAmount = paid.flatMap { UploadText.money($0.groups[0]) }
        guard let day = paid.flatMap({ UploadText.day($0.groups[1]) }) ?? periodStart else { throw LettingStatementError.missing("date") }
        if paid == nil { warnings.append("No payment date was found, so the rent period's first day is used.") }

        // Net, VAT and the total with VAT: the last is the cost.
        let fee = UploadText.first(#"Management fee[^£]{0,80}?"# + amount + #"\s+"# + amount + #"\s+"# + amount, in: text)
            .flatMap { UploadText.money($0.groups[2]) }
        let spent = UploadText.amount(after: "Total Expenditure", in: text)
        let total = spent ?? fee ?? 0
        var fees = fee ?? 0
        var repairs = total - fees
        var other: Decimal = 0
        if fee == nil && total > 0 {
            other = total
            repairs = 0
            warnings.append("The management fee couldn't be told apart: all costs are under Other costs.")
        } else if repairs < 0 {
            fees = total
            repairs = 0
            warnings.append("The management fee is more than the total costs. Check both.")
        } else if repairs > 0 {
            warnings.append("Costs besides the fee are put under repairs. Move any that aren't.")
        }

        let net = rent - fees - repairs - other
        var wrong = false
        if let paidAmount {
            if net != paidAmount {
                wrong = true
                warnings.insert("Rent less costs is \(TaxMoney.format(net)), but the statement says \(TaxMoney.format(paidAmount)) was paid.", at: 0)
            }
        } else {
            wrong = spent == nil
            warnings.append("No amount paid was found to check the figures against.")
        }
        let reference = UploadText.first(#"Statement reference\s*:\s*(\S+)"#, in: text)?.groups[0] ?? ""
        return LettingStatement(date: day, grossRent: rent, fees: fees, repairs: repairs, otherExpense: other, reference: reference,
                                isChecked: paidAmount != nil && !wrong, warnings: warnings, needsAttention: wrong)
    }

    private static func management(_ text: String) throws -> LettingStatement {
        let amount = UploadText.amount
        guard let received = UploadText.first(#"Rent received this statement\s*:?\s*"# + amount, in: text),
              let rent = UploadText.money(received.groups[0]), rent > 0 else { throw LettingStatementError.missing("rent received") }
        // The date printed just before the rent.
        let before = String(text[..<received.range.lowerBound])
        guard let day = UploadText.all(UploadText.date, in: before).last.flatMap({ UploadText.day($0.groups[0]) }) else {
            throw LettingStatementError.missing("date")
        }
        let commission = (UploadText.first(#"Invoice\s*:\s*"# + amount + #"\s*Total"#, in: text)
            ?? UploadText.first(#"Invoice\s*:\s*Total\s*:?\s*"# + amount, in: text))
            .flatMap { UploadText.money($0.groups[0]) }
        var warnings = ["This layout shows no amount paid to check against. Compare the figures with the statement."]
        let wrong = commission.map { $0 >= rent } ?? true
        if commission == nil { warnings.insert("The agent's commission couldn't be found.", at: 0) }
        if let commission, commission >= rent { warnings.insert("The commission isn't less than the rent. Check both.", at: 0) }
        let reference = UploadText.first(#"Statement No\.?\s*:?\s*(\d+)"#, in: text)?.groups[0] ?? ""
        return LettingStatement(date: day, grossRent: rent, fees: commission ?? 0, reference: reference, warnings: warnings, needsAttention: wrong)
    }

    /// A spreadsheet export: property, gross rent, management fee, other deductions, net
    /// payment and date, in that order, under a row of column names. Comma, tab or semicolon.
    public static func read(csv: String) throws -> [LettingStatement] {
        let lines = csv.replacingOccurrences(of: "\u{FEFF}", with: "").split(whereSeparator: \.isNewline)
            .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first, header.lowercased().contains("gross") else { throw LettingStatementError.notRecognised }
        let records: [[String]]
        if let separator = ["\t", ";"].first(where: { header.contains($0) }) {
            records = lines.map { $0.components(separatedBy: separator) }
        } else {
            records = CSVReader.records(lines.joined(separator: "\n"))
        }
        guard records.count > 1 else { throw LettingStatementError.missing("payments") }
        return try records.dropFirst().enumerated().map { index, record in
            let fields = record.map { $0.trimmingCharacters(in: .whitespaces) }
            func money(_ column: Int) throws -> Decimal {
                guard column < fields.count, let value = AmountParser.parse(fields[column].isEmpty ? "0" : fields[column], decimalComma: false) else {
                    throw LettingStatementError.missing("amounts on line \(index + 2)")
                }
                return abs(value)
            }
            let gross = try money(1), fee = try money(2), deductions = try money(3), net = try money(4)
            guard fields.count > 5, let day = UploadText.day(fields[5].replacingOccurrences(of: "-", with: "/")) else {
                throw LettingStatementError.missing("date on line \(index + 2)")
            }
            guard gross > 0 else { throw LettingStatementError.missing("rent on line \(index + 2)") }
            let wrong = gross - fee - deductions != net
            return LettingStatement(date: day, grossRent: gross, fees: fee, otherExpense: deductions,
                                    reference: fields.count > 6 ? fields[6] : "", propertyName: fields[0], isChecked: !wrong,
                                    warnings: wrong ? ["Rent less costs doesn't equal the net payment of \(TaxMoney.format(net))."] : [],
                                    needsAttention: wrong)
        }
    }
}

extension PropertyBook {
    /// True when this statement is here already, imported or typed in.
    public func has(_ statement: LettingStatement, propertyID: String) -> Bool {
        statements.contains {
            $0.propertyID == propertyID && $0.grossRent == statement.grossRent
                && TaxYear.calendar.isDate($0.date, inSameDayAs: statement.date)
        }
    }

    /// The bank payment a statement explains: money in of exactly what the agent paid, from a
    /// few days before the statement to two weeks after, that no other statement has.
    public func bankPayment(for statement: LettingStatement, in payments: [BankTransaction], excluding: Set<String> = []) -> BankTransaction? {
        let taken = excluding.union(statements.compactMap(\.bankFingerprint))
        let day: TimeInterval = 86_400
        return payments.filter {
            $0.amount == statement.paidToYou && $0.amount > 0 && !taken.contains($0.fingerprint)
                && $0.date.timeIntervalSince(statement.date) >= -3.5 * day && $0.date.timeIntervalSince(statement.date) <= 14.5 * day
        }
        .min { (abs($0.date.timeIntervalSince(statement.date)), $0.fingerprint) < (abs($1.date.timeIntervalSince(statement.date)), $1.fingerprint) }
    }

    /// Adds statements to a property, linking each to its bank payment so the rent isn't
    /// counted twice. Ones already here are left alone. Returns how many were added.
    @discardableResult
    public mutating func add(_ found: [LettingStatement], propertyID: String, payments: [BankTransaction]) -> Int {
        guard properties.contains(where: { $0.id == propertyID }) else { return 0 }
        var added = 0
        for statement in found.sorted(by: { $0.date < $1.date }) where !has(statement, propertyID: propertyID) {
            let day = PropertyLedger.day(statement.date)
            statements.append(AgentStatement(id: "upload|\(propertyID)|\(day)|\(statement.grossRent)", propertyID: propertyID,
                                             date: statement.date, grossRent: statement.grossRent, fees: statement.fees,
                                             repairs: statement.repairs, otherExpense: statement.otherExpense,
                                             bankFingerprint: bankPayment(for: statement, in: payments)?.fingerprint))
            added += 1
        }
        return added
    }
}
