import BudgetCore
import Foundation

/// One relief, allowance or claim for a person and year: the rule, the amounts, and whether
/// it's in the figures. The list covers what's claimed and what isn't, so nothing is silent.
public struct TaxClaim: Hashable, Sendable, Identifiable {
    public enum Status: String, Sendable {
        case claimed = "Claimed"
        case automatic = "Applied for you"
        case open = "Could be claimed"
        case none = "Nothing entered"
        case notDue = "Doesn't apply"
        case yourself = "Not worked out: claim it yourself"
    }

    public struct Line: Hashable, Sendable {
        public var label: String
        public var amount: Decimal
    }

    public var id: String
    public var group: String
    public var title: String
    /// The rule in plain words, with its limit.
    public var rule: String
    public var status: Status
    public var lines: [Line]
    /// How much less tax there is because of it, or would be for one that could be claimed.
    public var worth: Decimal?
    /// Where it goes on the return, or what to do.
    public var action: String

    static let marriageTransfer: Decimal = 1_260

    public static func list(_ person: Person, year: TaxYear, ledger: PropertyLedger, book: PropertyBook,
                            india: IndiaBook = IndiaBook(), today: Date = Date()) -> [TaxClaim] {
        let input = PersonInput.make(person, ledger: ledger, book: book, year: year, india: india)
        let result = TaxCalculator.estimate(input)
        var claims: [TaxClaim] = []
        func add(_ id: String, _ group: String, _ title: String, _ status: Status, rule: String,
                 lines: [(String, Decimal)] = [], worth: Decimal? = nil, action: String = "") {
            claims.append(TaxClaim(id: id, group: group, title: title, rule: rule, status: status,
                                   lines: lines.map { Line(label: $0.0, amount: $0.1) }, worth: worth, action: action))
        }
        /// The extra tax there would be without something.
        func saving(_ change: (inout PersonInput) -> Void) -> Decimal {
            var without = input
            change(&without)
            return max(0, TaxCalculator.estimate(without).liability - result.liability)
        }

        // Allowances.
        let allowances = "Allowances"
        let lost = TaxCalculator.allowance - result.personalAllowance
        add("personal", allowances, "Personal Allowance", .automatic,
            rule: "£12,570 of income is free of tax. It falls by £1 for every £2 of adjusted net income above £100,000.",
            lines: [("Allowance this year", result.personalAllowance)] + (lost > 0 ? [("Lost because of income over £100,000", lost)] : []),
            action: lost > 0 ? "Pension saving from take-home pay and Gift Aid lower adjusted net income and can win some back." : "")
        add("starting", allowances, "Starting rate for savings", result.startingRateUsed > 0 ? .automatic : .notDue,
            rule: "Up to £5,000 of interest at 0%, reduced pound for pound by pay and property profit above the Personal Allowance.",
            lines: [("Interest taxed at 0% by it", result.startingRateUsed)])
        add("savings", allowances, "Personal Savings Allowance", result.savingsAllowanceUsed > 0 ? .automatic : .notDue,
            rule: "£1,000 of interest at 0% for basic rate taxpayers, £500 for higher rate, none for additional rate.",
            lines: [("Your allowance", result.savingsAllowance), ("Used", result.savingsAllowanceUsed)])
        add("dividend", allowances, "Dividend allowance", result.dividendAllowanceUsed > 0 ? .automatic : .notDue,
            rule: "The first £500 of dividends is taxed at 0%.",
            lines: [("Used", result.dividendAllowanceUsed), ("Unused", TaxCalculator.dividendAllowance - result.dividendAllowanceUsed)])

        // Job expenses.
        let jobs = book.pay.filter { $0.person == person && $0.taxYear == year.description }
        let work = "Job expenses"
        let homeRule = year.startYear >= 2026 ? " Working from home can't be claimed from 6 April 2026."
            : " Working from home counts only if your job required it."
        let kinds: [(String, String, KeyPath<JobExpenses, Decimal>, WritableKeyPath<JobExpenses, Decimal>, String, String)] = [
            ("subscriptions", "Professional fees and subscriptions", \.subscriptions, \.subscriptions, "19",
             "Fees and subscriptions you paid to bodies on HMRC's approved list that your job needs."),
            ("travel", "Business travel and subsistence", \.travel, \.travel, "17",
             "Travel for work, not ordinary commuting, that you weren't repaid for. Umbrella company workers usually can't claim it."),
            ("flatRate", "Flat rate for uniforms, work clothing and tools", \.flatRate, \.flatRate, "18",
             "A fixed yearly amount HMRC agrees for some jobs."),
            ("otherJob", "Other job expenses and equipment", \.other, \.other, "20",
             "Costs needed wholly, exclusively and necessarily for the job." + homeRule)
        ]
        for (id, title, read, write, box, rule) in kinds {
            let amount = input.jobExpenses[keyPath: read]
            add(id, work, title, jobs.isEmpty ? .notDue : amount > 0 ? .claimed : .none, rule: rule,
                lines: amount > 0 ? [("Claimed", amount)] : [],
                worth: amount > 0 ? saving { $0.jobExpenses[keyPath: write] = 0 } : nil,
                action: "Employment page, box \(box). Enter it under the job in Pay and Statements, and keep receipts.")
        }

        // Pensions and giving.
        let giving = "Pensions and giving"
        let atSource = input.reliefAtSourcePension
        add("reliefAtSource", giving, "Pension paid from take-home pay", atSource > 0 ? .claimed : .none,
            rule: "The scheme adds basic rate relief. Higher and additional rate relief must be claimed on the return.",
            lines: atSource > 0 ? [("Paid in, including basic rate relief", atSource)] : [],
            worth: atSource > 0 ? saving { $0.reliefAtSourcePension = 0 } : nil,
            action: "Main return, page TR 4, box 1.")
        add("sacrifice", giving, "Salary sacrifice pension", input.pensionSacrificed > 0 ? .automatic : .none,
            rule: "Given up before pay is taxed, so the relief has already happened: don't claim it again.",
            lines: input.pensionSacrificed > 0 ? [("Given up from pay", input.pensionSacrificed)] : [])
        if let allowance = result.pensionAllowance {
            let saved = TaxMoney.poundsDown(input.pensionPaidIn)
            let within = min(saved, allowance)
            let carried = min(saved - within, TaxMoney.poundsDown(input.pensionUnused))
            add("annualAllowance", giving, "Pension annual allowance and carry forward", .automatic,
                rule: "£60,000 a year, less for high incomes. Unused allowance from the three earlier years can be added, if you were in a registered scheme.",
                lines: [("Paid in", saved), ("Within this year's allowance", within), ("Covered by allowance brought forward", carried),
                        ("Above what's allowed", result.pensionExcess), ("This year's allowance left to carry forward", allowance - within),
                        ("Charge on the excess", result.pensionCharge), ("Paid by your scheme", result.pensionSchemePaid)],
                action: result.pensionExcess > 0 ? "Additional information, page Ai 4, boxes 10 and 11." : "")
        } else {
            add("annualAllowance", giving, "Pension annual allowance and carry forward", .none,
                rule: "£60,000 a year, less for high incomes, plus unused allowance from the three earlier years.",
                action: "Enter the year's pension saving in Pay and Statements.")
        }
        add("giftAid", giving, "Gift Aid", input.giftAid > 0 ? .claimed : .none,
            rule: "Gifts to charity with a Gift Aid declaration. Higher and additional rate relief must be claimed.",
            lines: input.giftAid > 0 ? [("Gifts, with the basic rate tax added back", input.giftAid)] : [],
            worth: input.giftAid > 0 ? saving { $0.giftAid = 0 } : nil,
            action: "Main return, page TR 4, box 5.")

        // Property.
        if input.propertyCount > 0 {
            let property = "Property"
            let pages = result.pages
            let running = pages.ratesAndInsurance + pages.repairs + pages.professionalFees + pages.services + pages.otherExpense
            let costCategories: [PropertyCategory] = [.ratesAndInsurance, .repairs, .professionalFees, .services, .otherExpense]
            add("expenses", property, "Letting expenses", running > 0 ? .claimed : .none,
                rule: "Costs of running the let, such as insurance, repairs and agent fees. Improvements aren't included.",
                lines: [("Rents and other income", pages.income), ("Expenses claimed", running)],
                worth: running > 0 ? saving { input in for category in costCategories { input.property[category] = nil } } : nil,
                action: "UK property pages, boxes 24 to 29.")
            add("replacement", property, "Replacing domestic items", pages.replacementItems > 0 ? .claimed : .none,
                rule: "Like-for-like replacement of furniture, appliances and furnishings in a let home. The first purchase doesn't count.",
                lines: pages.replacementItems > 0 ? [("Claimed", pages.replacementItems)] : [],
                worth: pages.replacementItems > 0 ? saving { $0.property[.replacementItems] = nil } : nil,
                action: "UK property pages, box 36.")
            let finance = pages.financeCosts + pages.financeBroughtForward
            add("finance", property, "Mortgage interest relief", finance > 0 ? .claimed : .none,
                rule: "Interest and finance costs on a let home give a 20% reduction, limited by property profit and by other income above the allowance. What's unused carries forward.",
                lines: finance > 0 ? [("Costs this year", pages.financeCosts), ("Brought forward", pages.financeBroughtForward),
                                      ("Tax reduction given", result.financeReduction),
                                      ("Costs carried forward", result.financeCarriedForward)] : [],
                worth: finance > 0 ? result.financeReduction : nil,
                action: "UK property pages, boxes 44 and 45. Keep the carried forward figure for next year.")
            let broughtForward = TaxMoney.poundsUp(input.lossesBroughtForward)
            add("losses", property, "Property losses", pages.lossUsed > 0 || pages.lossCarriedForward > 0 ? .claimed : .none,
                rule: "A loss is carried forward and set against later profits of the same property business.",
                lines: [("Brought forward", broughtForward), ("Used this year", pages.lossUsed), ("Carried forward", pages.lossCarriedForward)],
                worth: pages.lossUsed > 0 ? saving { $0.lossesBroughtForward = 0 } : nil,
                action: "UK property pages, boxes 39 and 43.")
            // The £1,000 allowance instead of costs and finance relief.
            var flat = input
            for category in costCategories + [.replacementItems, .financeCost] { flat.property[category] = nil }
            flat.financeBroughtForward = 0
            flat.property[.otherIncome, default: 0] -= min(1_000, pages.income)
            let gain = result.liability - TaxCalculator.estimate(flat).liability
            add("propertyAllowance", property, "£1,000 property income allowance", gain > 0 ? .open : .notDue,
                rule: "Take £1,000 off property income instead of claiming expenses and mortgage interest relief. Not allowed on income from someone connected with you.",
                lines: [("Allowance", min(1_000, pages.income))], worth: gain > 0 ? gain : nil,
                action: gain > 0 ? "It looks cheaper than your actual costs. UK property pages, box 20.1. The estimate doesn't apply it."
                    : "Claiming your actual costs is at least as good.")
        }

        // Tax taken in India.
        let report = IndiaReport.make(india, year: year, person: person, today: today)
        func inPounds(_ rupees: Decimal) -> Decimal { max(0, IndiaMoney.pounds(rupees, rupeesPerPound: report.rupeesPerPound) ?? 0) }
        let abroad = "Tax taken in India"
        /// All the tax of one kind, and the part in accounts with no income of that kind.
        func withheld(_ tax: KeyPath<IndiaReport.Row, Decimal>, income: KeyPath<IndiaReport.Row, Decimal>) -> (all: Decimal, alone: Decimal) {
            let all = report.rows.reduce(Decimal(0)) { $0 + inPounds($1[keyPath: tax]) }
            let alone = report.rows.reduce(Decimal(0)) { $0 + ($1[keyPath: income] > 0 ? 0 : inPounds($1[keyPath: tax])) }
            return (TaxMoney.penceDown(all), TaxMoney.penceDown(alone))
        }
        let sources = [
            ("reliefInterest", "Relief for tax on interest", 15, withheld(\.taxDeducted, income: \.interest),
             input.foreignTax, result.foreignReliefInterest, input.foreignInterest),
            ("reliefDividends", "Relief for tax on dividends", 10, withheld(\.dividendTax, income: \.dividends),
             input.foreignDividendTax, result.foreignReliefDividends, input.foreignDividends)
        ]
        for (id, title, percent, taken, allowed, given, income) in sources {
            // The parts always add up to the tax taken.
            let limit = TaxMoney.penceDown(allowed)
            let over = taken.all - taken.alone - limit
            let unused = limit - given
            var lines: [(String, Decimal)] = []
            if taken.all > 0 {
                lines = [("Income", income), ("Tax taken in India", taken.all), ("Relief given here", given),
                         ("Above the treaty rate: reclaim in India", over), ("Not relieved: the UK tax on it is lower", unused)]
                if taken.alone > 0 { lines.append(("No income entered for this tax: check India Accounts", taken.alone)) }
            }
            add(id, abroad, title, input.isMissingRate ? .none : given > 0 ? .claimed : .notDue,
                rule: "Foreign Tax Credit Relief: no more than the treaty's \(percent)%, and no more than the UK tax on that income.",
                lines: lines,
                worth: given > 0 ? given : nil,
                action: input.isMissingRate ? "Enter the year's exchange rate in India Accounts." : "Foreign pages, columns C and E.")
        }

        // Between spouses.
        let couple = "Married couples and personal"
        let other = person.other
        let theirs = TaxCalculator.estimate(.make(other, ledger: ledger, book: book, year: year, india: india))
        let hasOther = theirs.pay > 0 || theirs.interest > 0 || theirs.dividends > 0 || theirs.pages.income > 0
        func canReceive(_ estimate: TaxEstimate) -> Bool { estimate.taxableIncome > 0 && estimate.taxableIncome <= estimate.basicRateLimit }
        func canGive(_ estimate: TaxEstimate) -> Bool { estimate.adjustedNetIncome < TaxCalculator.allowance }
        let marriageRule = "A spouse or civil partner with income under £12,570 can pass £1,260 of allowance to one who pays no more than basic rate, saving up to £252. Claims can go back to 6 April 2022."
        if hasOther, canGive(theirs), canReceive(result) {
            let worth = min(TaxMoney.penceDown(marriageTransfer * TaxCalculator.basicRate), result.taxBeforeReduction - result.financeReduction)
            add("marriage", couple, "Marriage Allowance", .open, rule: marriageRule, lines: [("Allowance received", marriageTransfer)],
                worth: worth, action: "Only if married or civil partners. The partner with the lower income applies. Not in the estimate.")
        } else if hasOther, canGive(result), canReceive(theirs) {
            add("marriage", couple, "Marriage Allowance", .open, rule: marriageRule, lines: [("Allowance you could pass on", marriageTransfer)],
                action: "Only if married or civil partners. It lowers your partner's tax by up to £252. Not in the estimate.")
        } else {
            add("marriage", couple, "Marriage Allowance", .notDue, rule: marriageRule,
                action: hasOther ? "On these figures one of you would need income under £12,570 and the other no higher rate tax."
                    : "No figures for a partner this year.")
        }
        add("blind", couple, "Blind Person's Allowance", .yourself,
            rule: "An extra allowance if registered blind or severely sight impaired.",
            lines: [("Allowance for \(year)", year.startYear >= 2026 ? 3_250 : 3_130)], action: "Main return, Blind Person's Allowance, box 13.")

        // What the app doesn't work out.
        let outside = "Not worked out by the app"
        add("gains", outside, "Capital gains exempt amount and losses", .yourself,
            rule: "The first £3,000 of gains is free of Capital Gains Tax. Losses must be claimed within 4 years to be carried forward.",
            action: "Capital gains pages (SA108). Not in the estimate yet.")
        add("rentARoom", outside, "Rent a Room relief", .yourself,
            rule: "Up to £7,500 a year of rent from a lodger in your own home is free of tax.", action: "UK property pages. Not for a separate let property.")
        add("investment", outside, "EIS, SEIS and Venture Capital Trust relief", .yourself,
            rule: "Income Tax relief for new shares in qualifying schemes, with the scheme's certificate.",
            action: "Additional information pages (SA101).")
        add("otherReliefs", outside, "Qualifying loan interest, maintenance and community investment relief", .yourself,
            rule: "Less common reliefs with their own conditions.", action: "Additional information pages (SA101).")

        // Already paid, which comes off the bill.
        let paid = "Already paid"
        add("paye", paid, "Tax taken off pay", result.taxDeducted > 0 ? .claimed : .none,
            rule: "Tax your employers took off is set against the bill.", lines: [("Taken off", result.taxDeducted)],
            action: "Employment pages, box 2.")
        add("onAccount", paid, "Payments on account made", result.advancePaid > 0 ? .claimed : .none,
            rule: "Advance payments already made for this year are set against the bill.", lines: [("Paid", result.advancePaid)],
            action: "HMRC already has them. Check them against your statement of account.")

        // Time limit for earlier years.
        if let current = TaxYear.containing(today) {
            let oldest = TaxYear(startYear: current.startYear - 4)
            add("earlier", "Earlier years", "Claims for \(oldest) close on 5 April \(current.startYear + 1)", .yourself,
                rule: "Most claims, such as job expenses, overpaid tax and capital losses, must be made within 4 years of the end of the tax year.",
                action: "Check \(oldest) onwards for anything missed. Not worked out here.")
        }
        return claims
    }
}
