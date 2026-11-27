import BudgetCore
import Foundation

/// Interest and dividends in rupee accounts for one UK tax year and one person, in rupees and
/// pounds, for the tax estimate, an accountant and the foreign pages (SA106).
public struct IndiaReport: Hashable, Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public var id: String { account.id }
        public var account: IndiaAccount
        /// This person's share, before any tax taken off in India.
        public var interest: Decimal
        public var taxDeducted: Decimal
        /// Dividends before tax, and the tax taken off them.
        public var dividends: Decimal = 0
        public var dividendTax: Decimal = 0
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

    /// What the UK-India treaty lets India take from interest paid to a UK resident.
    public static let treatyRate = Decimal(15) / 100

    /// The most India may take from ordinary dividends paid to a UK resident.
    public static let dividendTreatyRate = Decimal(10) / 100

    public struct Pounds: Hashable, Sendable {
        public var interest: Decimal = 0
        /// The Indian tax that can be relieved here, account by account and no more than the
        /// treaty allows.
        public var interestTax: Decimal = 0
        public var dividends: Decimal = 0
        public var dividendTax: Decimal = 0
    }

    /// In pounds. Nil without a rate.
    public var inPounds: Pounds? {
        guard let rate = rupeesPerPound, rate > 0 else { return nil }
        func income(_ rupees: Decimal, tax: Decimal, limit: Decimal) -> (Decimal, Decimal) {
            guard rupees > 0 else { return (0, 0) }
            let pounds = IndiaMoney.pounds(rupees, rupeesPerPound: rate) ?? 0
            let withheld = max(0, IndiaMoney.pounds(tax, rupeesPerPound: rate) ?? 0)
            return (pounds, min(withheld, TaxMoney.penceDown(pounds * limit)))
        }
        var total = Pounds()
        for row in rows {
            let interest = income(row.interest, tax: row.taxDeducted, limit: Self.treatyRate)
            let dividends = income(row.dividends, tax: row.dividendTax, limit: Self.dividendTreatyRate)
            total.interest += interest.0
            total.interestTax += interest.1
            total.dividends += dividends.0
            total.dividendTax += dividends.1
        }
        return total
    }

    public var interest: Decimal { rows.reduce(0) { $0 + $1.interest } }
    public var taxDeducted: Decimal { rows.reduce(0) { $0 + $1.taxDeducted } }
    public var interestPounds: Decimal? { IndiaMoney.pounds(interest, rupeesPerPound: rupeesPerPound) }
    public var taxPounds: Decimal? { IndiaMoney.pounds(taxDeducted, rupeesPerPound: rupeesPerPound) }
    public var dividends: Decimal { rows.reduce(0) { $0 + $1.dividends } }
    public var dividendTax: Decimal { rows.reduce(0) { $0 + $1.dividendTax } }

    public static func make(_ book: IndiaBook, year: TaxYear, person: Person, today: Date = Date()) -> IndiaReport {
        var rows: [Row] = []
        var warnings: [String] = []
        for account in book.accounts.sorted(by: { ($0.title, $0.id) < ($1.title, $1.id) }) {
            let share = account.share(of: person)
            guard share > 0 else { continue }
            let inYear = book.entries.filter { $0.accountID == account.id && year.contains($0.date) }
            func total(_ kind: IndiaEntry.Kind) -> Decimal { inYear.filter { $0.kind == kind }.reduce(0) { $0 + $1.amount } }
            let interest = total(.interest) * share, tax = -total(.taxDeducted) * share
            let dividends = total(.dividend) * share, dividendTax = -total(.dividendTax) * share
            let statement = inYear.filter { !$0.isManual }.map(\.date)
            rows.append(Row(account: account, interest: interest, taxDeducted: tax, dividends: dividends, dividendTax: dividendTax,
                            firstLine: statement.min(), lastLine: statement.max()))

            if inYear.isEmpty {
                warnings.append("\(account.title): nothing entered for \(year).")
            } else if interest == 0 && dividends == 0 {
                warnings.append("\(account.title): no interest found. Check the bank's interest certificate.")
            }
            if inYear.contains(where: { $0.isManual && $0.kind == .interest }), inYear.contains(where: { !$0.isManual && $0.kind == .interest }) {
                warnings.append("\(account.title): has interest both typed in and from statements. Check none is counted twice.")
            }
            if inYear.contains(where: { !$0.isManual && $0.kind == .dividend }) {
                warnings.append("\(account.title): a dividend marked on a statement is usually the amount after tax. Replace it with the amount before tax, and add the tax, from Form 26AS or the company's statement.")
            }
            // The UK year ends five days into India's next one, which an Indian year's papers miss.
            let all = book.entries.filter { $0.accountID == account.id }
            let april = TaxYear.day(year.startYear + 1, 4, 1)
            if today >= year.end, !inYear.isEmpty, !all.contains(where: { $0.date >= april }) {
                warnings.append("\(account.title): nothing from 1 April \(year.startYear + 1) on. Add any interest, dividend or tax dated 1 to 5 April \(year.startYear + 1), from India's FY \(TaxYear(startYear: year.startYear + 1)).")
            }
            if inYear.contains(where: { $0.isManual && $0.date >= april - 86_400 && $0.date < april }) {
                warnings.append("\(account.title): a figure typed in for 31 March may be a whole Indian year's. India's FY \(year) includes 1 to 5 April \(year.startYear), which belongs to the UK year before: take that part off.")
            }
            if dividends == 0, dividendTax != 0 {
                warnings.append("\(account.title): tax on dividends is entered but no dividend.")
            }
            if account.kind == .nro, interest > 0, tax == 0 {
                warnings.append("\(account.title): no tax deducted found. If the bank paid interest after tax, change the figures to the amounts on its certificate.")
            }
        }
        if rows.contains(where: { $0.taxDeducted > 0 || $0.dividendTax > 0 }) {
            warnings.append("Relief is only for tax India finally kept. If your Indian return gave any of it back, enter the tax after the refund.")
        }
        let rate = book.rate(year.description)
        if rate == nil, !rows.isEmpty { warnings.insert("Enter the rupees to a pound for \(year) to see pounds.", at: 0) }
        if today < year.end, !rows.isEmpty { warnings.append("\(year) isn't over: these are the figures so far.") }
        return IndiaReport(year: year, person: person, rows: rows, rupeesPerPound: rate, warnings: warnings)
    }

    /// A spreadsheet of the totals and every interest and tax line behind them.
    public func csv(_ book: IndiaBook) -> String {
        var table = [["Tax year", "Account", "Date", "What", "Share", "Interest INR", "Tax deducted INR", "Interest GBP", "Tax deducted GBP",
                      "Dividends INR", "Dividend tax INR", "Dividends GBP", "Dividend tax GBP", "Rupees per pound", "Details", "Indian year"]]
        let rate = rupeesPerPound.map { "\($0)" } ?? ""
        func pounds(_ value: Decimal) -> String { IndiaMoney.pounds(value, rupeesPerPound: rupeesPerPound).map { "\($0)" } ?? "" }
        func money(_ value: Decimal) -> String { "\(TaxMoney.round(value, scale: 2, .plain))" }
        for row in rows {
            let share = row.account.share(of: person)
            for entry in book.entries(of: row.account.id).reversed() where year.contains(entry.date) && entry.kind != .other {
                let interest = entry.kind == .interest ? entry.amount * share : 0
                let tax = entry.kind == .taxDeducted ? -entry.amount * share : 0
                let dividend = entry.kind == .dividend ? entry.amount * share : 0
                let dividendTax = entry.kind == .dividendTax ? -entry.amount * share : 0
                table.append([year.description, row.account.title, PropertyLedger.day(entry.date), entry.kind.title, "\(share)",
                              money(interest), money(tax), pounds(interest), pounds(tax),
                              money(dividend), money(dividendTax), pounds(dividend), pounds(dividendTax), rate, entry.narration,
                              TaxYear.indianYear(of: entry.date)])
            }
        }
        table.append([year.description, "Total", "", "", "", money(interest), money(taxDeducted), pounds(interest), pounds(taxDeducted),
                      money(dividends), money(dividendTax), pounds(dividends), pounds(dividendTax), rate, "", ""])
        return table.map { $0.map(CSVExporter.escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
