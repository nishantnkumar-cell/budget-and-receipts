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

    public init() {}

    public static func make(_ person: Person, ledger: PropertyLedger, book: PropertyBook, year: TaxYear) -> PersonInput {
        var input = PersonInput()
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

    public static func estimate(_ input: PersonInput) -> TaxEstimate {
        let pages = pages(input)
        let pay = TaxMoney.poundsDown(input.pay)
        let pension = TaxMoney.poundsUp(input.reliefAtSourcePension)
        let total = pay + pages.taxableProfit
        // Relief-at-source pensions and Gift Aid widen the lower bands and protect the allowance.
        let widening = pension + TaxMoney.poundsUp(input.giftAid)
        let adjustedNet = max(0, total - widening)
        let reduction = TaxMoney.poundsDown(max(0, adjustedNet - taperStart) / 2)
        let personalAllowance = max(0, allowance - reduction)

        let taxable = max(0, total - personalAllowance)
        let basicLimit = basicBand + widening
        let higherLimit = additionalThreshold + widening
        let tax = TaxMoney.penceDown(
            min(taxable, basicLimit) * basicRate
            + max(0, min(taxable, higherLimit) - basicLimit) * higherRate
            + max(0, taxable - higherLimit) * additionalRate)

        // Finance cost relief: basic rate on the lowest of the costs, the property profit and
        // the income above the personal allowance. What isn't used carries forward.
        let finance = pages.financeCosts + pages.financeBroughtForward
        let relievable = max(0, min(finance, pages.taxableProfit, total - personalAllowance))
        let financeReduction = min(tax, TaxMoney.penceDown(relievable * basicRate))
        let liability = tax - financeReduction

        let deducted = TaxMoney.poundsUp(input.taxDeducted)
        // Advance payments for next year depend on the bill before any made for this one.
        let bill = liability - deducted
        let advancePaid = TaxMoney.penceDown(input.advancePaid)
        let balance = bill - advancePaid
        let needsAdvance = bill >= 1_000 && deducted <= liability * Decimal(80) / 100
        return TaxEstimate(
            pay: pay, pages: pages, adjustedNetIncome: adjustedNet, personalAllowance: personalAllowance,
            taxBeforeReduction: tax, financeReduction: financeReduction,
            financeCarriedForward: finance - relievable, liability: liability, taxDeducted: deducted,
            advancePaid: advancePaid, balance: balance,
            paymentOnAccount: needsAdvance ? TaxMoney.penceDown(bill / 2) : nil)
    }
}
