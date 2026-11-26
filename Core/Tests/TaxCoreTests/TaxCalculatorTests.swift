import BudgetCore
import XCTest
@testable import TaxCore

/// Expected figures are worked out by hand from the 2025-26 rates.
final class TaxCalculatorTests: XCTestCase {
    private func input(pay: Decimal = 0, rent: Decimal = 0, expenses: Decimal = 0, finance: Decimal = 0,
                       deducted: Decimal = 0, pension: Decimal = 0) -> PersonInput {
        var input = PersonInput()
        input.pay = pay
        input.taxDeducted = deducted
        input.reliefAtSourcePension = pension
        input.property = [.rent: rent, .otherExpense: expenses, .financeCost: finance]
        return input
    }

    func testAdditionalRateWithFinanceRelief() {
        let result = TaxCalculator.estimate(input(pay: 150_000, rent: 10_000, finance: 4_000, deducted: 53_703))
        XCTAssertEqual(result.personalAllowance, 0)
        XCTAssertEqual(result.taxBeforeReduction, 58_203)
        XCTAssertEqual(result.financeReduction, 800)
        XCTAssertEqual(result.liability, 57_403)
        XCTAssertEqual(result.balance, 3_700)
        // Over 80% was collected from pay, so no advance payments.
        XCTAssertNil(result.paymentOnAccount)
    }

    func testAllowanceTaperCostsSixtyPercent() {
        let before = TaxCalculator.estimate(input(pay: 105_000))
        let after = TaxCalculator.estimate(input(pay: 105_000, rent: 10_000))
        XCTAssertEqual(before.liability, 30_432)
        XCTAssertEqual(after.personalAllowance, 5_070)
        XCTAssertEqual(after.liability - before.liability, 6_000)
    }

    func testAllowanceIsGoneAtTheThreshold() {
        XCTAssertEqual(TaxCalculator.estimate(input(pay: 125_139)).personalAllowance, 1)
        XCTAssertEqual(TaxCalculator.estimate(input(pay: 125_140)).personalAllowance, 0)
    }

    func testPensionRestoresAllowanceAndWidensBasicBand() {
        let result = TaxCalculator.estimate(input(pay: 110_000, pension: 10_000))
        XCTAssertEqual(result.adjustedNetIncome, 100_000)
        XCTAssertEqual(result.personalAllowance, 12_570)
        XCTAssertEqual(result.liability, 29_432)
    }

    func testFinanceReliefLimitedByProfitCarriesForward() {
        let result = TaxCalculator.estimate(input(pay: 60_000, rent: 3_000, finance: 5_000))
        XCTAssertEqual(result.financeReduction, 600)
        XCTAssertEqual(result.financeCarriedForward, 2_000)
    }

    func testFinanceReliefLimitedByIncomeAboveAllowance() {
        let result = TaxCalculator.estimate(input(rent: 15_000, finance: 8_000))
        XCTAssertEqual(result.taxBeforeReduction, 486)
        XCTAssertEqual(result.financeReduction, 486)
        XCTAssertEqual(result.liability, 0)
        XCTAssertEqual(result.financeCarriedForward, 5_570)
    }

    func testLossesAreCarriedForwardAndUsed() {
        let loss = TaxCalculator.pages(input(rent: 5_000, expenses: 8_000))
        XCTAssertEqual(loss.adjustedLoss, 3_000)
        XCTAssertEqual(loss.taxableProfit, 0)
        XCTAssertEqual(loss.lossCarriedForward, 3_000)
        var next = input(rent: 9_000, expenses: 8_000)
        next.lossesBroughtForward = 3_000
        let pages = TaxCalculator.pages(next)
        XCTAssertEqual(pages.lossUsed, 1_000)
        XCTAssertEqual(pages.taxableProfit, 0)
        XCTAssertEqual(pages.lossCarriedForward, 2_000)
    }

    func testAdvancePaymentsWhenLittleWasDeducted() {
        let result = TaxCalculator.estimate(input(rent: 30_000))
        XCTAssertEqual(result.liability, 3_486)
        XCTAssertEqual(result.paymentOnAccount, 1_743)
    }

    func testAdvancePaymentsAlreadyMadeComeOffTheBalance() {
        var paid = input(rent: 30_000)
        paid.advancePaid = 3_486
        let result = TaxCalculator.estimate(paid)
        XCTAssertEqual(result.balance, 0)
        XCTAssertEqual(result.paymentOnAccount, 1_743)
    }

    func testGiftAidRestoresTheAllowance() {
        var giving = input(pay: 105_000)
        giving.giftAid = 4_000
        let result = TaxCalculator.estimate(giving)
        XCTAssertEqual(result.personalAllowance, 12_070)
        XCTAssertEqual(result.liability, 28_832)
    }

    func testARefundBiggerThanTheCostsIsIncome() {
        var refunded = input(rent: 1_000)
        refunded.property[.repairs] = -100
        let pages = TaxCalculator.pages(refunded)
        XCTAssertEqual(pages.repairs, 0)
        XCTAssertEqual(pages.income, 1_100)
        XCTAssertEqual(pages.taxableProfit, 1_100)
    }

    func testBoxesRoundInTheTaxpayersFavour() {
        let pages = TaxCalculator.pages(input(rent: Decimal(string: "1000.99")!, expenses: Decimal(string: "10.01")!))
        XCTAssertEqual(pages.income, 1_000)
        XCTAssertEqual(pages.otherExpense, 11)
    }

    func testNewPropertyIsCheapestForTheLowerRateSpouse() {
        let options = OwnershipComparison.compare(
            NewProperty(yearlyRent: 10_000, yearlyExpenses: 0, yearlyInterest: 0),
            me: input(pay: 150_000), partner: input(pay: 105_000))
        XCTAssertEqual(options.map(\.myShare), [1, Decimal(1) / 2, 0])
        XCTAssertEqual(options.map(\.total), [4_500, 5_250, 6_000])
    }

    func testTypedAmounts() {
        XCTAssertEqual(TaxMoney.parse("£1,250.50"), Decimal(string: "1250.50"))
        XCTAssertEqual(TaxMoney.parse("0"), 0)
        for bad in ["", "-5", "1.234", "12a", "1..2"] { XCTAssertNil(TaxMoney.parse(bad), bad) }
        XCTAssertEqual(TaxMoney.format(Decimal(string: "-1234567.5")!), "-£1,234,567.50")
    }
}
