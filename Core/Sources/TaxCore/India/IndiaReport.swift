import BudgetCore
import Foundation

/// Interest from rupee accounts for one UK tax year and one person, in rupees and pounds, to
/// give an accountant or copy to the foreign pages (SA106). It isn't part of the tax estimate.
public struct IndiaReport: Hashable, Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public var id: String { account.id }
        public var account: IndiaAccount
        /// This person's share, before any tax taken off in India.
        public var interest: Decimal
        public var taxDeducted: Decimal
        /// The first and last statement line in the year, to show what's covered.
        public var firstLine: Date?
        public var lastLine: Date?
    }

    public var year: TaxYear
    public var person: Person
    public var rows: [Row]
    public var rupeesPerPound: Decimal?
    /// Things to check before using the figures.
    public var warnings: [String]

    public var interest: Decimal { rows.reduce(0) { $0 + $1.interest } }
    public var taxDeducted: Decimal { rows.reduce(0) { $0 + $1.taxDeducted } }
    public var interestPounds: Decimal? { IndiaMoney.pounds(interest, rupeesPerPound: rupeesPerPound) }
    public var taxPounds: Decimal? { IndiaMoney.pounds(taxDeducted, rupeesPerPound: rupeesPerPound) }

    public static func make(_ book: IndiaBook, year: TaxYear, person: Person, today: Date = Date()) -> IndiaReport {
        var rows: [Row] = []
        var warnings: [String] = []
        for account in book.accounts.sorted(by: { ($0.title, $0.id) < ($1.title, $1.id) }) {
            let share = account.share(of: person)
            guard share > 0 else { continue }
            let inYear = book.entries.filter { $0.accountID == account.id && year.contains($0.date) }
            func total(_ kind: IndiaEntry.Kind) -> Decimal { inYear.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount } }
            let interest = total(.interest) * share, tax = -total(.taxDeducted) * share
            let statement = inYear.filter { !$0.isManual }.map(\.date)
            rows.append(Row(account: account, interest: interest, taxDeducted: tax, firstLine: statement.min(), lastLine: statement.max()))

            if inYear.isEmpty {
                warnings.append("\(account.title): nothing entered for \(year).")
            } else if interest == 0 {
                warnings.append("\(account.title): no interest found. Check the bank's interest certificate.")
            }
            if inYear.contains(where: { $0.isManual && $0.kind == .interest }), inYear.contains(where: { !$0.isManual && $0.kind == .interest }) {
                warnings.append("\(account.title): has interest both typed in and from statements. Check none is counted twice.")
            }
            if account.kind == .nro, interest > 0, tax == 0 {
                warnings.append("\(account.title): no tax deducted found. If the bank paid interest after tax, change the figures to the amounts on its certificate.")
            }
        }
        let rate = book.rate(year.description)
        if rate == nil, !rows.isEmpty { warnings.insert("Enter the rupees to a pound for \(year) to see pounds.", at: 0) }
        if today < year.end, !rows.isEmpty { warnings.append("\(year) isn't over: these are the figures so far.") }
        return IndiaReport(year: year, person: person, rows: rows, rupeesPerPound: rate, warnings: warnings)
    }

    /// A spreadsheet of the totals and every interest and tax line behind them.
    public func csv(_ book: IndiaBook) -> String {
        var table = [["Tax year", "Account", "Date", "What", "Share", "Interest INR", "Tax deducted INR", "Interest GBP", "Tax deducted GBP", "Rupees per pound", "Details"]]
        let rate = rupeesPerPound.map { "\($0)" } ?? ""
        func pounds(_ value: Decimal) -> String { IndiaMoney.pounds(value, rupeesPerPound: rupeesPerPound).map { "\($0)" } ?? "" }
        func money(_ value: Decimal) -> String { "\(TaxMoney.round(value, scale: 2, .plain))" }
        for row in rows {
            let share = row.account.share(of: person)
            for entry in book.entries(of: row.account.id).reversed() where year.contains(entry.date) && entry.kind != .other {
                let interest = entry.kind == .interest ? entry.amount * share : 0
                let tax = entry.kind == .taxDeducted ? -entry.amount * share : 0
                table.append([year.description, row.account.title, PropertyLedger.day(entry.date), entry.kind.title, "\(share)",
                              money(interest), money(tax), pounds(interest), pounds(tax), rate, entry.narration])
            }
        }
        table.append([year.description, "Total", "", "", "", money(interest), money(taxDeducted), pounds(interest), pounds(taxDeducted), rate, ""])
        return table.map { $0.map(CSVExporter.escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
