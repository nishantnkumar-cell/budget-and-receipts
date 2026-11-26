import BudgetCore
import Foundation

/// "In whose name should we buy?": the extra tax a new property would add to the household.
public struct NewProperty: Hashable, Sendable {
    public var yearlyRent: Decimal
    public var yearlyExpenses: Decimal
    public var yearlyInterest: Decimal

    public init(yearlyRent: Decimal, yearlyExpenses: Decimal, yearlyInterest: Decimal) {
        self.yearlyRent = yearlyRent
        self.yearlyExpenses = yearlyExpenses
        self.yearlyInterest = yearlyInterest
    }
}

public struct OwnershipOption: Hashable, Sendable {
    public var myShare: Decimal
    public var myExtraTax: Decimal
    public var partnerExtraTax: Decimal
    public var total: Decimal { myExtraTax + partnerExtraTax }
}

public enum OwnershipComparison {
    static func adding(_ property: NewProperty, share: Decimal, to input: PersonInput) -> PersonInput {
        guard share > 0 else { return input }
        var input = input
        input.property[.rent, default: 0] += property.yearlyRent * share
        input.property[.otherExpense, default: 0] += property.yearlyExpenses * share
        input.property[.financeCost, default: 0] += property.yearlyInterest * share
        input.propertyCount += 1
        if share < 1 { input.hasJointProperty = true }
        return input
    }

    /// Mine alone, half each and my spouse's alone, cheapest first. A full year of income tax
    /// only: stamp duty and capital gains tax are not included.
    public static func compare(_ property: NewProperty, me: PersonInput, partner: PersonInput) -> [OwnershipOption] {
        let before = (TaxCalculator.estimate(me).liability, TaxCalculator.estimate(partner).liability)
        return [Decimal(1), Decimal(string: "0.5")!, Decimal(0)].map { share in
            OwnershipOption(
                myShare: share,
                myExtraTax: TaxCalculator.estimate(adding(property, share: share, to: me)).liability - before.0,
                partnerExtraTax: TaxCalculator.estimate(adding(property, share: 1 - share, to: partner)).liability - before.1)
        }
        .sorted { $0.total < $1.total }
    }
}
