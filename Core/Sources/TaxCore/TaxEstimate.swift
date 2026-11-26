import BudgetCore
import Foundation

/// One person's figures before any tax is worked out. Amounts may include pence.
public struct PersonInput: Hashable, Sendable {
    public var pay: Decimal = 0
    public var taxDeducted: Decimal = 0
    public var reliefAtSourcePension: Decimal = 0
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
    /// True when there is interest from India but no exchange rate, so it's left out.
    public var isMissingRate = false

    public init() {}

    public static func make(_ person: Person, ledger: PropertyLedger, book: PropertyBook, year: TaxYear,
                            india: IndiaBook = IndiaBook()) -> PersonInput {
        var input = PersonInput()
        input.year = year
        let report = IndiaReport.make(india, year: year, person: person)
        if let pounds = report.inPounds {
            input.foreignInterest = pounds.interest
            input.foreignTax = pounds.relievableTax
        } else {
            input.isMissingRate = report.rows.contains { $0.interest > 0 }
        }
        for job in book.pay where job.person == person && job.taxYear == year.description {
            input.pay += job.taxablePay
            input.taxDeducted += job.taxDeducted
            input.reliefAtSourcePension += job.reliefAtSourcePension
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
    /// All interest, and the part of it from India.
    public var interest: Decimal
    public var foreignInterest: Decimal
    public var dividends: Decimal
    /// The tax on interest and on dividends, included in `taxBeforeReduction`.
    public var savingsTax: Decimal
    public var dividendTax: Decimal
    /// Relief for tax India took.
    public var foreignRelief: Decimal
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

    public static func estimate(_ input: PersonInput) -> TaxEstimate {
        var result = beforeForeignRelief(input)
        guard input.foreignInterest > 0, input.foreignTax > 0 else { return result }
        // Relief is the smaller of the Indian tax allowed and the UK tax the interest causes:
        // the bill with it less the bill without it.
        var without = input
        without.foreignInterest = 0
        let caused = max(0, result.liability - beforeForeignRelief(without).liability)
        let relief = min(TaxMoney.penceDown(input.foreignTax), caused)
        result.foreignRelief = relief
        result.liability -= relief
        settle(&result)
        return result
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
        let earned = pay + pages.taxableProfit
        let foreign = TaxMoney.poundsDown(input.foreignInterest)
        let interest = TaxMoney.poundsDown(input.ukInterest) + foreign
        let dividends = TaxMoney.poundsDown(input.dividends)
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
        func tax(allowanceOnInterest used: Decimal) -> (savings: Decimal, dividends: Decimal) {
            let taxableInterest = interest - used
            let taxableDividends = max(0, dividends - (spare - used))
            let starting = min(taxableInterest, startingLeft)
            let free = starting + min(taxableInterest - starting, savingsAllowance)
            let under = taxableEarned + taxableInterest
            return (banded(taxableEarned + free, under, basicLimit: basicLimit, higherLimit: higherLimit, rates: ordinary),
                    banded(under + min(taxableDividends, dividendAllowance), under + taxableDividends,
                           basicLimit: basicLimit, higherLimit: higherLimit, rates: dividendRates(input.year)))
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
        let (savingsTax, dividendTax) = best
        let tax = TaxMoney.penceDown(earnedTax + savingsTax + dividendTax)

        // Finance cost relief: basic rate on the lowest of the costs, the property profit and
        // the income other than savings and dividends above the personal allowance. What
        // isn't used carries forward.
        let finance = pages.financeCosts + pages.financeBroughtForward
        let relievable = max(0, min(finance, pages.taxableProfit, earned - personalAllowance))
        let financeReduction = min(tax, TaxMoney.penceDown(relievable * basicRate))

        var result = TaxEstimate(
            pay: pay, interest: interest, foreignInterest: foreign, dividends: dividends,
            savingsTax: TaxMoney.penceDown(savingsTax), dividendTax: TaxMoney.penceDown(dividendTax), foreignRelief: 0,
            pages: pages, adjustedNetIncome: adjustedNet, personalAllowance: personalAllowance,
            taxBeforeReduction: tax, financeReduction: financeReduction,
            financeCarriedForward: finance - relievable, liability: tax - financeReduction,
            taxDeducted: TaxMoney.poundsUp(input.taxDeducted), advancePaid: TaxMoney.penceDown(input.advancePaid),
            balance: 0, paymentOnAccount: nil)
        settle(&result)
        return result
    }
}
