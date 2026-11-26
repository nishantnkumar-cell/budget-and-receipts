import BudgetCore
import Foundation

/// One person's figures before any tax is worked out. Amounts may include pence.
public struct PersonInput: Hashable, Sendable {
    public var pay: Decimal = 0
    public var taxDeducted: Decimal = 0
    public var reliefAtSourcePension: Decimal = 0
    /// Job expenses, each job's limited to its own pay.
    public var jobExpenses = JobExpenses()
    /// Their share of each property category.
    public var property: [PropertyCategory: Decimal] = [:]
    public var propertyCount = 0
    public var hasJointProperty = false
    public var lossesBroughtForward: Decimal = 0
    public var financeBroughtForward: Decimal = 0
    public var advancePaid: Decimal = 0
    public var giftAid: Decimal = 0
    public var year = TaxYear(startYear: 2025)
    /// Interest from UK banks and dividends from UK companies, outside ISAs.
    public var ukInterest: Decimal = 0
    public var dividends: Decimal = 0
    /// Interest from India in pounds, and the Indian tax on it that can be relieved.
    public var foreignInterest: Decimal = 0
    public var foreignTax: Decimal = 0
    /// Dividends from India in pounds, and the Indian tax on them that can be relieved.
    public var foreignDividends: Decimal = 0
    public var foreignDividendTax: Decimal = 0
    /// Pension saving for the annual allowance (see `PensionYear`).
    public var pensionPaidIn: Decimal = 0
    public var pensionSacrificed: Decimal = 0
    public var pensionUnused: Decimal = 0
    public var pensionSchemePays: Decimal = 0
    /// True when there is income from India but no exchange rate, so it's left out.
    public var isMissingRate = false

    public init() {}

    public static func make(_ person: Person, ledger: PropertyLedger, book: PropertyBook, year: TaxYear,
                            india: IndiaBook = IndiaBook()) -> PersonInput {
        var input = PersonInput()
        input.year = year
        let report = IndiaReport.make(india, year: year, person: person)
        if let pounds = report.inPounds {
            input.foreignInterest = pounds.interest
            input.foreignTax = pounds.interestTax
            input.foreignDividends = pounds.dividends
            input.foreignDividendTax = pounds.dividendTax
        } else {
            input.isMissingRate = report.rows.contains { $0.interest > 0 || $0.dividends > 0 }
        }
        for job in book.pay where job.person == person && job.taxYear == year.description {
            input.pay += job.taxablePay
            input.taxDeducted += job.taxDeducted
            input.reliefAtSourcePension += job.reliefAtSourcePension
            if let expenses = job.expenses, expenses.total > 0 {
                // Costs can't take a job below nothing.
                let part = min(1, max(0, job.taxablePay) / expenses.total)
                input.jobExpenses.travel += expenses.travel * part
                input.jobExpenses.flatRate += expenses.flatRate * part
                input.jobExpenses.subscriptions += expenses.subscriptions * part
                input.jobExpenses.other += expenses.other * part
            }
        }
        for property in book.properties {
            var counts = false
            for line in ledger.lines where line.propertyID == property.id && line.category.isCounted {
                let share = property.share(of: person, on: line.date, in: year)
                guard share > 0 else { continue }
                counts = true
                if share < 1 { input.hasJointProperty = true }
                input.property[line.category, default: 0] += line.amount * share
            }
            if counts { input.propertyCount += 1 }
        }
        for entry in book.figures where entry.person == person && entry.taxYear == year.description {
            input.lossesBroughtForward += entry.losses
            input.financeBroughtForward += entry.financeCosts
            input.advancePaid += entry.advancePaid
            input.giftAid += entry.giftAid
            input.ukInterest += entry.ukInterest ?? 0
            input.dividends += entry.ukDividends ?? 0
            input.pensionPaidIn += entry.pension?.paidIn ?? 0
            input.pensionSacrificed += entry.pension?.sacrificed ?? 0
            input.pensionUnused += entry.pension?.unused ?? 0
            input.pensionSchemePays += entry.pension?.schemePays ?? 0
        }
        return input
    }
}

/// The UK property pages (SA105, 2025-26 box numbers), in whole pounds.
public struct PropertyPages: Hashable, Sendable {
    public var propertyCount: Int          // 1
    public var joint: Bool                 // 3
    public var income: Decimal             // 20
    public var ratesAndInsurance: Decimal  // 24
    public var repairs: Decimal            // 25
    public var professionalFees: Decimal   // 27
    public var services: Decimal           // 28
    public var otherExpense: Decimal       // 29
    public var replacementItems: Decimal   // 36
    public var adjustedProfit: Decimal     // 38
    public var lossUsed: Decimal           // 39
    public var taxableProfit: Decimal      // 40
    public var adjustedLoss: Decimal       // 41
    public var lossCarriedForward: Decimal // 43
    public var financeCosts: Decimal       // 44
    public var financeBroughtForward: Decimal // 45

    public var boxes: [(box: String, title: String, value: String)] {
        let money: [(String, String, Decimal)] = [
            ("20", "Total rents and other income", income),
            ("24", "Rent, rates, insurance and ground rents", ratesAndInsurance),
            ("25", "Property repairs and maintenance", repairs),
            ("27", "Legal, management and professional fees", professionalFees),
            ("28", "Costs of services provided", services),
            ("29", "Other allowable property expenses", otherExpense),
            ("36", "Costs of replacing domestic items", replacementItems),
            ("38", "Adjusted profit for the year", adjustedProfit),
            ("39", "Loss brought forward used", lossUsed),
            ("40", "Taxable profit for the year", taxableProfit),
            ("41", "Adjusted loss for the year", adjustedLoss),
            ("43", "Loss to carry forward", lossCarriedForward),
            ("44", "Residential property finance costs", financeCosts),
            ("45", "Unused finance costs brought forward", financeBroughtForward)
        ]
        return [("1", "Number of properties rented out", "\(propertyCount)"),
                ("3", "Property let jointly", joint ? "X" : "")]
            + money.map { ($0.0, $0.1, TaxMoney.format($0.2)) }
    }
}

public struct TaxEstimate: Hashable, Sendable {
    public var pay: Decimal
    /// All interest and all dividends, and the parts from India.
    public var interest: Decimal
    public var foreignInterest: Decimal
    public var dividends: Decimal
    public var foreignDividends: Decimal
    /// The tax on interest and on dividends, included in `taxBeforeReduction`.
    public var savingsTax: Decimal
    public var dividendTax: Decimal
    /// Relief for tax India took, and how much of it is for interest and for dividends.
    public var foreignRelief: Decimal
    public var foreignReliefInterest: Decimal = 0
    public var foreignReliefDividends: Decimal = 0
    /// Job expenses taken off pay.
    public var jobExpenses: Decimal = 0
    /// Income taxed at nothing by the starting rate, the savings allowance (and its size) and
    /// the dividend allowance.
    public var startingRateUsed: Decimal = 0
    public var savingsAllowance: Decimal = 0
    public var savingsAllowanceUsed: Decimal = 0
    public var dividendAllowanceUsed: Decimal = 0
    /// All income after allowances, and where the higher rate starts.
    public var taxableIncome: Decimal = 0
    public var basicRateLimit: Decimal = 0
    /// This year's pension annual allowance. Nil when no pension saving was entered.
    public var pensionAllowance: Decimal?
    /// Saving above the allowance and what was carried forward, the charge on it, and the part
    /// the scheme pays. The rest is included in `liability`.
    public var pensionExcess: Decimal
    public var pensionCharge: Decimal
    public var pensionSchemePaid: Decimal
    public var pages: PropertyPages
    public var adjustedNetIncome: Decimal
    public var personalAllowance: Decimal
    public var taxBeforeReduction: Decimal
    public var financeReduction: Decimal
    public var financeCarriedForward: Decimal
    public var liability: Decimal
    public var taxDeducted: Decimal
    public var advancePaid: Decimal
    /// Still to pay for this year; negative means HMRC owes a refund.
    public var balance: Decimal
    /// Each of the two advance payments for next year, when they apply.
    public var paymentOnAccount: Decimal?
}

public enum TaxCalculator {
    // England, Wales and Northern Ireland, 2025-26 and 2026-27.
    static let allowance: Decimal = 12_570
    static let taperStart: Decimal = 100_000
    static let basicBand: Decimal = 37_700
    static let additionalThreshold: Decimal = 125_140
    static let basicRate = Decimal(20) / 100
    static let higherRate = Decimal(40) / 100
    static let additionalRate = Decimal(45) / 100

    public static func pages(_ input: PersonInput) -> PropertyPages {
        func value(_ category: PropertyCategory) -> Decimal { input.property[category] ?? 0 }
        // Refunds bigger than the year's costs of that kind are money received.
        let refunds = PropertyCategory.allCases.filter { $0.isCounted && !$0.isIncome }.reduce(Decimal(0)) { $0 + max(0, -value($1)) }
        let income = TaxMoney.poundsDown(value(.rent) + value(.otherIncome) + refunds)
        func cost(_ category: PropertyCategory) -> Decimal { max(0, TaxMoney.poundsUp(value(category))) }
        let rates = cost(.ratesAndInsurance), repairs = cost(.repairs), fees = cost(.professionalFees)
        let services = cost(.services), other = cost(.otherExpense), items = cost(.replacementItems)
        let result = income - rates - repairs - fees - services - other - items
        let profit = max(0, result)
        let loss = max(0, -result)
        let broughtForward = TaxMoney.poundsUp(input.lossesBroughtForward)
        let used = min(profit, broughtForward)
        return PropertyPages(
            propertyCount: input.propertyCount, joint: input.hasJointProperty, income: income,
            ratesAndInsurance: rates, repairs: repairs, professionalFees: fees, services: services,
            otherExpense: other, replacementItems: items, adjustedProfit: profit, lossUsed: used,
            taxableProfit: profit - used, adjustedLoss: loss, lossCarriedForward: loss + broughtForward - used,
            financeCosts: cost(.financeCost), financeBroughtForward: TaxMoney.poundsUp(input.financeBroughtForward))
    }

    static let startingBand: Decimal = 5_000
    static let dividendAllowance: Decimal = 500

    private static func dividendRates(_ year: TaxYear) -> (basic: Decimal, higher: Decimal, additional: Decimal) {
        // The first two rates rose by two points from April 2026.
        let rise: Decimal = year.startYear >= 2026 ? Decimal(2) / 100 : 0
        return (Decimal(875) / 10_000 + rise, Decimal(3375) / 10_000 + rise, Decimal(3935) / 10_000)
    }

    /// The tax on one slice of income that sits from `start` to `end` of taxable income.
    private static func banded(_ start: Decimal, _ end: Decimal, basicLimit: Decimal, higherLimit: Decimal,
                               rates: (basic: Decimal, higher: Decimal, additional: Decimal)) -> Decimal {
        func part(_ low: Decimal, _ high: Decimal) -> Decimal { max(0, min(end, high) - max(start, low)) }
        let top = max(end, higherLimit)
        return part(0, basicLimit) * rates.basic + part(basicLimit, higherLimit) * rates.higher + part(higherLimit, top) * rates.additional
    }

    static let pensionAllowance: Decimal = 60_000
    private static let pensionThresholdIncome: Decimal = 200_000
    private static let pensionAdjustedIncome: Decimal = 260_000
    private static let pensionMinimum: Decimal = 10_000

    public static func estimate(_ input: PersonInput) -> TaxEstimate {
        var result = beforeForeignRelief(input)
        let relief = foreignRelief(input)
        result.foreignReliefInterest = relief.interest
        result.foreignReliefDividends = relief.dividends
        result.foreignRelief = relief.interest + relief.dividends
        // The pension charge is added after relief: foreign tax can't be set against it.
        result.liability += result.pensionCharge - result.pensionSchemePaid - result.foreignRelief
        settle(&result)
        return result
    }

    /// Relief for each kind of Indian income is the smaller of the tax allowed and the UK tax
    /// that income causes: the bill with it less the bill without it. Kinds already counted
    /// stay left out, and the order giving most relief is used.
    private static func foreignRelief(_ input: PersonInput) -> (interest: Decimal, dividends: Decimal) {
        let sources: [(income: WritableKeyPath<PersonInput, Decimal>, tax: Decimal)] = [
            (\.foreignInterest, TaxMoney.penceDown(input.foreignTax)),
            (\.foreignDividends, TaxMoney.penceDown(input.foreignDividendTax))
        ]
        func relief(_ order: [Int]) -> [Decimal] {
            var remaining = input, given: [Decimal] = [0, 0]
            for index in order {
                let source = sources[index]
                guard remaining[keyPath: source.income] > 0, source.tax > 0 else { continue }
                var without = remaining
                without[keyPath: source.income] = 0
                let caused = beforeForeignRelief(remaining).liability - beforeForeignRelief(without).liability
                given[index] = min(source.tax, max(0, caused))
                remaining = without
            }
            return given
        }
        let first = relief([0, 1]), second = relief([1, 0])
        let best = first[0] + first[1] >= second[0] + second[1] ? first : second
        return (best[0], best[1])
    }

    /// What's still to pay, and next year's advance payments, from the bill.
    private static func settle(_ result: inout TaxEstimate) {
        // Advance payments for next year depend on the bill before any made for this one.
        let bill = result.liability - result.taxDeducted
        result.balance = bill - result.advancePaid
        let needsAdvance = bill >= 1_000 && result.taxDeducted <= result.liability * Decimal(80) / 100
        result.paymentOnAccount = needsAdvance ? TaxMoney.penceDown(bill / 2) : nil
    }

    private static func beforeForeignRelief(_ input: PersonInput) -> TaxEstimate {
        let pages = pages(input)
        let pay = TaxMoney.poundsDown(input.pay)
        let pension = TaxMoney.poundsUp(input.reliefAtSourcePension)
        let costs = input.jobExpenses
        let expenses = min(pay, TaxMoney.poundsUp(costs.travel) + TaxMoney.poundsUp(costs.flatRate)
            + TaxMoney.poundsUp(costs.subscriptions) + TaxMoney.poundsUp(costs.other))
        let earned = pay - expenses + pages.taxableProfit
        let foreign = TaxMoney.poundsDown(input.foreignInterest)
        let interest = TaxMoney.poundsDown(input.ukInterest) + foreign
        let foreignDividends = TaxMoney.poundsDown(input.foreignDividends)
        let dividends = TaxMoney.poundsDown(input.dividends) + foreignDividends
        let total = earned + interest + dividends
        // Relief-at-source pensions and Gift Aid widen the lower bands and protect the allowance.
        let widening = pension + TaxMoney.poundsUp(input.giftAid)
        let adjustedNet = max(0, total - widening)
        let reduction = TaxMoney.poundsDown(max(0, adjustedNet - taperStart) / 2)
        let personalAllowance = max(0, allowance - reduction)

        // The allowance goes against pay and property first. What's left may be set against
        // interest and dividends in whichever way costs least.
        let taxableEarned = max(0, earned - personalAllowance)
        let spare = max(0, personalAllowance - earned)

        let basicLimit = basicBand + widening
        let higherLimit = additionalThreshold + widening
        let ordinary = (basic: basicRate, higher: higherRate, additional: additionalRate)
        let earnedTax = banded(0, taxableEarned, basicLimit: basicLimit, higherLimit: higherLimit, rates: ordinary)

        // Interest: first any of the £5,000 starting band that pay didn't use, then the
        // savings allowance, which depends on the highest band any income reaches.
        // Dividends sit on top; the first £500 is taxed at nothing but still fills the bands.
        let everything = taxableEarned + max(0, interest + dividends - spare)
        let savingsAllowance: Decimal = everything > higherLimit ? 0 : everything > basicLimit ? 500 : 1_000
        let startingLeft = max(0, startingBand - taxableEarned)
        func tax(allowanceOnInterest used: Decimal) -> (savings: Decimal, dividends: Decimal, starting: Decimal, saved: Decimal, nilDividends: Decimal) {
            let taxableInterest = interest - used
            let taxableDividends = max(0, dividends - (spare - used))
            let starting = min(taxableInterest, startingLeft)
            let free = starting + min(taxableInterest - starting, savingsAllowance)
            let under = taxableEarned + taxableInterest
            return (banded(taxableEarned + free, under, basicLimit: basicLimit, higherLimit: higherLimit, rates: ordinary),
                    banded(under + min(taxableDividends, dividendAllowance), under + taxableDividends,
                           basicLimit: basicLimit, higherLimit: higherLimit, rates: dividendRates(input.year)),
                    starting, free - starting, min(taxableDividends, dividendAllowance))
        }
        // The cheapest split is at one end, or where interest or dividends just reach a nil band,
        // or where the point they meet (or the end of the £500) crosses into a higher band.
        let least = min(interest, max(0, spare - dividends)), most = min(interest, spare)
        let crossings = [basicLimit, higherLimit].flatMap { limit in
            [taxableEarned + interest - limit, taxableEarned + interest + dividendAllowance - limit]
        }
        let turns = [least, interest - startingLeft - savingsAllowance, interest - startingLeft,
                     spare - dividends + dividendAllowance] + crossings
        // Interest takes the allowance first unless another split is cheaper.
        var best = tax(allowanceOnInterest: most)
        for turn in turns {
            let other = tax(allowanceOnInterest: min(most, max(least, turn)))
            if other.savings + other.dividends < best.savings + best.dividends { best = other }
        }
        let (savingsTax, dividendTax, startingUsed, savedUsed, nilDividends) = best

        // Pension saving above the annual allowance is taxed as the top slice of income.
        var allowanceForPension: Decimal?
        var pensionExcess: Decimal = 0, pensionCharge: Decimal = 0
        if input.pensionPaidIn > 0 {
            // High incomes get less: both tests count the contributions differently.
            let thresholdIncome = total - pension + TaxMoney.poundsDown(input.pensionSacrificed)
            let adjustedIncome = total + max(0, TaxMoney.poundsDown(input.pensionPaidIn) - pension)
            var yearly = pensionAllowance
            if thresholdIncome > pensionThresholdIncome && adjustedIncome > pensionAdjustedIncome {
                yearly = max(pensionMinimum, yearly - TaxMoney.poundsDown((adjustedIncome - pensionAdjustedIncome) / 2))
            }
            allowanceForPension = yearly
            pensionExcess = max(0, TaxMoney.poundsDown(input.pensionPaidIn) - yearly - TaxMoney.poundsDown(input.pensionUnused))
            pensionCharge = TaxMoney.penceDown(banded(everything, everything + pensionExcess, basicLimit: basicLimit,
                                                      higherLimit: higherLimit, rates: ordinary))
        }
        let tax = TaxMoney.penceDown(earnedTax + savingsTax + dividendTax)

        // Finance cost relief: basic rate on the lowest of the costs, the property profit and
        // the income other than savings and dividends above the personal allowance. What
        // isn't used carries forward.
        let finance = pages.financeCosts + pages.financeBroughtForward
        let relievable = max(0, min(finance, pages.taxableProfit, earned - personalAllowance))
        let financeReduction = min(tax, TaxMoney.penceDown(relievable * basicRate))

        var result = TaxEstimate(
            pay: pay, interest: interest, foreignInterest: foreign, dividends: dividends,
            foreignDividends: foreignDividends,
            savingsTax: TaxMoney.penceDown(savingsTax), dividendTax: TaxMoney.penceDown(dividendTax), foreignRelief: 0,
            pensionAllowance: allowanceForPension, pensionExcess: pensionExcess, pensionCharge: pensionCharge,
            pensionSchemePaid: min(pensionCharge, TaxMoney.penceDown(max(0, input.pensionSchemePays))),
            pages: pages, adjustedNetIncome: adjustedNet, personalAllowance: personalAllowance,
            taxBeforeReduction: tax, financeReduction: financeReduction,
            financeCarriedForward: finance - relievable, liability: tax - financeReduction,
            taxDeducted: TaxMoney.poundsUp(input.taxDeducted), advancePaid: TaxMoney.penceDown(input.advancePaid),
            balance: 0, paymentOnAccount: nil)
        result.jobExpenses = expenses
        result.startingRateUsed = startingUsed
        result.savingsAllowance = savingsAllowance
        result.savingsAllowanceUsed = savedUsed
        result.dividendAllowanceUsed = nilDividends
        result.taxableIncome = everything
        result.basicRateLimit = basicLimit
        settle(&result)
        return result
    }
}
