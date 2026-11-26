import BudgetCore
import Foundation

/// The HMRC forms this app can fill in, for the 2025-26 tax year.
public enum ReturnFormKind: String, CaseIterable, Sendable {
    case main = "SA100", employment = "SA102", property = "SA105", foreign = "SA106"

    public var title: String {
        switch self {
        case .main: "Main tax return"
        case .employment: "Employment"
        case .property: "UK property"
        case .foreign: "Foreign"
        }
    }

    /// Where the blank form is on GOV.UK.
    public var download: URL {
        let page = switch self {
        case .main: "self-assessment-tax-return-sa100"
        case .employment: "self-assessment-employment-sa102"
        case .property: "self-assessment-uk-property-sa105"
        case .foreign: "self-assessment-foreign-sa106"
        }
        return URL(string: "https://www.gov.uk/government/publications/\(page)")!
    }
}

public enum ReturnValue: Hashable, Sendable {
    /// Whole pounds: forms leave out the pence.
    case pounds(Int)
    case count(Int)
    case tick
    case text(String)

    /// As shown on the box-by-box sheet.
    public var shown: String {
        switch self {
        case .pounds(let value): String(TaxMoney.format(Decimal(value)).dropLast(3))
        case .count(let value): "\(value)"
        case .tick: "X (tick)"
        case .text(let text): text
        }
    }
}

public struct ReturnEntry: Hashable, Sendable, Identifiable {
    /// Finds the box's place on the form (see `ReturnLayout`).
    public var id: String
    /// The box as the form numbers it, with its page for the main return.
    public var box: String
    public var label: String
    public var value: ReturnValue
}

/// One copy of one form.
public struct ReturnForm: Hashable, Sendable, Identifiable {
    public var kind: ReturnFormKind
    /// What tells copies apart, e.g. the employer.
    public var detail: String
    public var entries: [ReturnEntry]
    public var id: String { "\(kind.rawValue)|\(detail)" }
    public var title: String { "\(kind.rawValue) \(kind.title)" + (detail.isEmpty ? "" : ": \(detail)") }
}

/// Everything to put on one person's forms for a year, with what to sort out first.
public struct ReturnPack: Hashable, Sendable {
    public var year: TaxYear
    public var person: Person
    public var forms: [ReturnForm]
    /// While any of these stand, the figures can't be relied on.
    public var problems: [String]
    /// Things the app can't know, to deal with before sending.
    public var checks: [String]

    public var isReady: Bool { problems.isEmpty && !forms.isEmpty }

    /// The only year whose form box numbers and layouts are built in.
    public static let year = TaxYear(startYear: 2025)
    /// Paper returns for that year had to reach HMRC before this.
    static let paperLate = TaxYear.day(2026, 11, 1)
    static let treatyRate = IndiaReport.treatyRate

    private static func down(_ value: Decimal) -> Int { NSDecimalNumber(decimal: TaxMoney.poundsDown(value)).intValue }
    private static func up(_ value: Decimal) -> Int { NSDecimalNumber(decimal: TaxMoney.poundsUp(value)).intValue }

    /// `sharedHousehold` is true when the other person uses the app on their own devices, so
    /// what they keep private isn't here.
    public static func make(_ person: Person, year: TaxYear, ledger: PropertyLedger, book: PropertyBook,
                            india: IndiaBook = IndiaBook(), sharedHousehold: Bool = false, today: Date = Date()) -> ReturnPack {
        guard year == Self.year else {
            return ReturnPack(year: year, person: person, forms: [],
                              problems: ["Only the 2025-26 forms are built in. Choose that tax year."], checks: [])
        }
        var problems = ledger.issues.filter(\.blocksFiling).map(\.message)
        var checks: [String] = []
        if sharedHousehold && person != .me {
            problems.append("This is made only from what your partner shares with this device: pay, figures, accounts and payments they keep private are missing. Make their forms on their own device.")
        }
        if today >= paperLate {
            checks.append("Paper returns for 2025-26 had to reach HMRC by 31 October 2026, so posting these now means a late filing penalty (unless HMRC's letter to you gave a later date). File online by 31 January 2027, copying these figures.")
        }
        var main: [ReturnEntry] = []
        var forms: [ReturnForm] = []
        func entry(_ id: String, _ box: String, _ label: String, _ value: ReturnValue) -> ReturnEntry {
            ReturnEntry(id: id, box: box, label: label, value: value)
        }

        // Employment pages, one for each employer.
        let jobs = book.pay.filter { $0.person == person && $0.taxYear == year.description }
            .sorted { ($0.employer.lowercased(), $0.id) < ($1.employer.lowercased(), $1.id) }
        // A job entered twice would be taxed twice.
        for employer in book.repeatedPay(in: year) where jobs.contains(where: { $0.employer == employer }) {
            problems.append(PropertyBook.repeatedPayProblem(employer))
        }
        let figures = Dictionary(grouping: jobs.filter { $0.taxablePay != 0 }) { "\($0.taxablePay)|\($0.taxDeducted)" }
        for same in figures.values.filter({ $0.count > 1 }).sorted(by: { $0[0].employer < $1[0].employer }) {
            let names = same.map(\.employer).joined(separator: " and ")
            // Two jobs can pay the same. It's taken for one job entered twice only when the
            // names are alike, or one came from a payslip and another was typed in.
            if Set(same.map { shortName($0.employer) }).count < same.count {
                problems.append("\(names) show the same pay and tax under much the same name, so they look like one job entered twice. Keep one in Pay and Statements.")
            } else if same.contains(where: { $0.payslipDate != nil }) && same.contains(where: { $0.payslipDate == nil }) {
                problems.append("\(names) show the same pay and tax, one from a payslip and one typed in, so they look like one job entered twice. Keep one in Pay and Statements, or if they are two jobs, open the payslip's entry and save it.")
            } else {
                checks.append("\(names) show the same pay and tax. Make sure they are different jobs.")
            }
        }
        // The form wants the year's total, from the P60 or P45. A payslip's figures to date
        // only stand for that when it's from the end of the year.
        for job in jobs {
            if let paid = job.payslipDate, paid < year.end.addingTimeInterval(-35 * 86_400) {
                problems.append("Pay from \(job.employer) is only up to a payslip of \(PropertyLedger.day(paid)). Import the year's last payslip, or check the figures against your P60 or P45 in Pay and Statements and save them.")
            }
        }
        for job in jobs {
            var entries = [entry("SA102.1", "1", "Pay from this employment", .pounds(down(job.taxablePay))),
                           entry("SA102.2", "2", "UK tax taken off pay", .pounds(up(job.taxDeducted)))]
            if !job.employer.isEmpty { entries.append(entry("SA102.5", "5", "Your employer's name", .text(job.employer))) }
            forms.append(ReturnForm(kind: .employment, detail: job.employer, entries: entries))
        }
        if !jobs.isEmpty {
            checks.append("Employment pages: compare boxes 1 and 2 with each P60 or P45, add your employer's PAYE reference (box 4) and answer boxes 6 to 8. Add any benefits and expenses.")
            if jobs.count > 1 { checks.append("There's more than one employment page: make sure each is a different job.") }
        }

        // UK property pages.
        let input = PersonInput.make(person, ledger: ledger, book: book, year: year, india: india)
        if input.propertyCount > 0 {
            let pages = TaxCalculator.pages(input)
            var entries = [entry("SA105.1", "1", "Number of properties rented out", .count(pages.propertyCount))]
            if pages.joint { entries.append(entry("SA105.3", "3", "Income from property let jointly", .tick)) }
            let money: [(String, String, Decimal)] = [
                ("20", "Total rents and other income from property", pages.income),
                ("24", "Rent, rates, insurance and ground rents", pages.ratesAndInsurance),
                ("25", "Property repairs and maintenance", pages.repairs),
                ("27", "Legal, management and other professional fees", pages.professionalFees),
                ("28", "Costs of services provided", pages.services),
                ("29", "Other allowable property expenses", pages.otherExpense),
                ("36", "Costs of replacing domestic items", pages.replacementItems),
                ("38", "Adjusted profit for the year", pages.adjustedProfit),
                ("39", "Loss brought forward used against this year's profits", pages.lossUsed),
                ("40", "Taxable profit for the year", pages.taxableProfit),
                ("41", "Adjusted loss for the year", pages.adjustedLoss),
                ("43", "Loss to carry forward", pages.lossCarriedForward),
                ("44", "Residential property finance costs", pages.financeCosts),
                ("45", "Unused residential finance costs brought forward", pages.financeBroughtForward)
            ]
            // A box that doesn't apply is left blank, except that a profit used up by losses
            // is shown as nothing left.
            for (box, label, value) in money where value > 0 || (box == "40" && pages.adjustedProfit > 0) {
                entries.append(entry("SA105.\(box)", box, label, .pounds(down(value))))
            }
            forms.append(ReturnForm(kind: .property, detail: "", entries: entries))
            let costs = pages.ratesAndInsurance + pages.repairs + pages.professionalFees + pages.services
                + pages.otherExpense + pages.replacementItems
            if pages.income > 0 && (pages.income <= 1_000 || costs < 1_000) {
                checks.append("With property income or costs of £1,000 or less, the property income allowance may matter: you may not need property pages, or may claim it (box 20.1) instead of costs. The app doesn't apply it; read the UK property notes.")
            }
        }

        // Interest from rupee accounts.
        let report = IndiaReport.make(india, year: year, person: person, today: today)
        let earned = report.rows.filter { $0.interest > 0 }
        if !earned.isEmpty {
            if report.rupeesPerPound == nil {
                problems.append("Enter the rupees to a pound for \(year) in India Accounts, so the interest from India can be put in pounds.")
            } else {
                foreign(earned, rate: report.rupeesPerPound, main: &main, forms: &forms, checks: &checks, entry: entry)
            }
        }
        if !report.rows.isEmpty {
            checks += report.warnings.filter { !$0.contains("rupees to a pound") }
        }

        // Savings and dividends entered for the year.
        if input.ukInterest >= 1 {
            main.append(entry("SA100.TR3.2", "TR 3, box 2", "Untaxed UK interest", .pounds(down(input.ukInterest))))
        }
        if input.dividends >= 1 {
            main.append(entry("SA100.TR3.4", "TR 3, box 4", "Dividends from UK companies", .pounds(down(input.dividends))))
        }

        // Reliefs on the main return.
        if input.reliefAtSourcePension > 0 {
            main.append(entry("SA100.TR4.1", "TR 4, box 1", "Pension payments with basic rate relief, including the relief",
                              .pounds(up(input.reliefAtSourcePension))))
        }
        if input.giftAid > 0 {
            // The app holds the amount with the tax added back; the form asks for what you paid.
            main.append(entry("SA100.TR4.5", "TR 4, box 5", "Gift Aid payments made in the year",
                              .pounds(up(input.giftAid * Decimal(4) / 5))))
        }

        // "What makes up your return": only the answers the app knows to be yes.
        var answers: [ReturnEntry] = []
        let employments = forms.filter { $0.kind == .employment }.count
        if employments > 0 {
            answers.append(entry("SA100.TR2.1", "TR 2, question 1", "Employment pages: Yes", .tick))
            answers.append(entry("SA100.TR2.1n", "TR 2, question 1", "Number of employment pages", .count(employments)))
        }
        if forms.contains(where: { $0.kind == .property }) {
            answers.append(entry("SA100.TR2.4", "TR 2, question 4", "UK property pages: Yes", .tick))
        }
        if forms.contains(where: { $0.kind == .foreign }) {
            answers.append(entry("SA100.TR2.5", "TR 2, question 5", "Foreign pages: Yes", .tick))
        }
        if !answers.isEmpty || !main.isEmpty {
            forms.insert(ReturnForm(kind: .main, detail: "", entries: answers + main), at: 0)
            checks.append("Main return: write your name, tax reference and National Insurance number, answer every question the app left blank, then sign and date it.")
            checks.append("UK interest and dividends are only what you entered in Pay and Statements: include every account outside ISAs, and move any interest that had tax taken off to box 1.")
            checks.append("Add anything the app doesn't hold, such as dividends and other income from abroad, capital gains, student loan or Child Benefit.")
        }
        if input.advancePaid > 0 {
            checks.append("Payments on account you've made aren't entered on the forms: HMRC already has them.")
        }
        checks += ledger.issues.filter { !$0.blocksFiling }.map(\.message)
        if forms.isEmpty && problems.isEmpty { problems.append("There's nothing to put on a return for this person yet.") }
        return ReturnPack(year: year, person: person, forms: forms, problems: problems, checks: checks)
    }

    /// An employer's name without capitals, punctuation or "Limited".
    private static func shortName(_ name: String) -> String {
        name.lowercased().split { !($0.isLetter || $0.isNumber) }
            .filter { !["ltd", "limited", "plc", "llp"].contains(String($0)) }.joined(separator: " ")
    }

    /// Interest goes on the foreign pages, or in one box of the main return when none of it
    /// was taxed and it's £2,000 or less.
    private static func foreign(_ rows: [IndiaReport.Row], rate: Decimal?, main: inout [ReturnEntry], forms: inout [ReturnForm],
                                checks: inout [String], entry: (String, String, String, ReturnValue) -> ReturnEntry) {
        func pounds(_ rupees: Decimal) -> Decimal { IndiaMoney.pounds(rupees, rupeesPerPound: rate) ?? 0 }
        let total = pounds(rows.reduce(0) { $0 + $1.interest })
        let taxed = rows.contains { $0.taxDeducted > 0 }
        if !taxed && total <= 2_000 {
            guard down(total) > 0 else { return }
            main.append(entry("SA100.TR3.3", "TR 3, box 3", "Untaxed foreign interest (up to £2,000)", .pounds(down(total))))
            main.append(entry("SA100.TR7.19", "TR 7, box 19", "Any other information",
                              .text("Page TR 3, box 3: the interest arose in India.")))
            checks.append("TR 3 box 3 only works if this interest is your only foreign income. If you have other foreign income, or claim the foreign income and gains regime, use the Foreign pages instead.")
            return
        }

        // One row for the interest India taxed and one for the rest: the notes ask for a
        // country's amounts to be added together unless they're taxed differently. Tax that
        // can be relieved is no more than the treaty allows, account by account.
        var withTax: (interest: Decimal, tax: Decimal) = (0, 0)
        var without: Decimal = 0
        var excess: Decimal = 0
        for row in rows {
            let interest = pounds(row.interest)
            let withheld = max(0, pounds(row.taxDeducted))
            let allowed = TaxMoney.penceDown(interest * treatyRate)
            excess += max(0, withheld - allowed)
            if withheld > 0 {
                withTax.interest += interest
                withTax.tax += min(withheld, allowed)
            } else {
                without += interest
            }
        }
        let lines = [withTax, (interest: without, tax: Decimal(0))]
        var entries: [ReturnEntry] = []
        var sum = 0
        var row = 0
        for line in lines where down(line.interest) > 0 {
            row += 1
            let amount = down(line.interest)
            // Rounded up, but never past the treaty's share of the figure in column B.
            let tax = min(up(line.tax), down(Decimal(amount) * treatyRate))
            sum += amount
            entries.append(entry("SA106.A\(row)", "F 2, column A, row \(row)", "Country code", .text("IND")))
            entries.append(entry("SA106.B\(row)", "F 2, column B, row \(row)", "Interest before any tax", .pounds(amount)))
            if tax > 0 {
                entries.append(entry("SA106.C\(row)", "F 2, column C, row \(row)", "Foreign tax taken off", .pounds(tax)))
                entries.append(entry("SA106.E\(row)", "F 3, column E, row \(row)", "Claiming Foreign Tax Credit Relief", .tick))
            }
            // Claiming relief, or with no tax to take away, the taxable amount is column B.
            entries.append(entry("SA106.F\(row)", "F 3, column F, row \(row)", "Taxable amount", .pounds(amount)))
        }
        guard sum > 0 else { return }
        entries.append(entry("SA106.4", "F 3, box 4", "Total of column F", .pounds(sum)))
        forms.append(ReturnForm(kind: .foreign, detail: "", entries: entries))
        if excess >= Decimal(1) / 100 {
            checks.append("India took \(TaxMoney.format(excess)) more than the 15% the UK-India treaty allows. Column C shows only what can be relieved here; ask your accountant about claiming the rest in India.")
        }
        checks.append("Foreign pages: check the figures against the banks' interest certificates. NRE interest that India doesn't tax is normally still taxable in the UK.")
    }
}
