import BudgetCore
import XCTest
@testable import TaxCore

/// Worked by hand from the 2025-26 and 2026-27 rates and bands. All figures are made up.
final class SavingsTaxTests: XCTestCase {
    private func estimate(pay: Decimal = 0, interest: Decimal = 0, dividends: Decimal = 0, foreign: Decimal = 0,
                          foreignTax: Decimal = 0, year: Int = 2025) -> TaxEstimate {
        var input = PersonInput()
        input.pay = pay
        input.ukInterest = interest
        input.dividends = dividends
        input.foreignInterest = foreign
        input.foreignTax = foreignTax
        input.year = TaxYear(startYear: year)
        return TaxCalculator.estimate(input)
    }

    private func pounds(_ text: String) -> Decimal { Decimal(string: text)! }

    func testAHigherRatePayerHasAnAllowanceOfFiveHundredOnEach() {
        let result = estimate(pay: 60_000, interest: 2_000, dividends: 3_000)
        XCTAssertEqual(result.savingsTax, 600)
        XCTAssertEqual(result.dividendTax, pounds("843.75"))
        XCTAssertEqual(result.liability, pounds("12875.75"))
        let later = estimate(pay: 60_000, interest: 2_000, dividends: 3_000, year: 2026)
        XCTAssertEqual(later.dividendTax, pounds("893.75"))
        XCTAssertEqual(later.liability, pounds("12925.75"))
    }

    func testTheStartingBandShrinksAsPayRisesAboveTheAllowance() {
        // £2,430 of pay is taxable, so £2,570 of the starting band is left, then £1,000.
        let result = estimate(pay: 15_000, interest: 10_000)
        XCTAssertEqual(result.savingsTax, 1_286)
        XCTAssertEqual(result.liability, 1_772)
        // With no pay the allowance covers interest first, then both nil bands.
        XCTAssertEqual(estimate(interest: 20_000).liability, 286)
        XCTAssertEqual(estimate(interest: 18_570).liability, 0)
    }

    func testTheAllowanceGoesWhereItSavesMost() {
        // All of it against dividends leaves the interest in the starting band:
        // £7,430 of dividends, £500 at nothing and £6,930 at 8.75%.
        let result = estimate(interest: 5_000, dividends: 20_000)
        XCTAssertEqual(result.savingsTax, 0)
        XCTAssertEqual(result.dividendTax, pounds("606.37"))
        // Checked against every whole-pound split.
        for (interest, dividends) in [(18_000, 5_000), (9_000, 6_000), (40_000, 30_000), (3_000, 13_000)] {
            let got = estimate(interest: Decimal(interest), dividends: Decimal(dividends)).liability
            var cheapest: Double = .greatestFiniteMagnitude
            for used in max(0, 12_570 - dividends)...min(interest, 12_570) {
                let taxable = Double(interest - used), shares = Double(max(0, dividends - (12_570 - used)))
                let allowance: Double = taxable + shares > 37_700 ? 500 : 1_000
                let nil_ = min(taxable, 5_000 + allowance)
                func part(_ start: Double, _ end: Double, _ basic: Double, _ higher: Double) -> Double {
                    max(0, min(end, 37_700) - start) * basic + max(0, end - max(start, 37_700)) * higher
                }
                cheapest = min(cheapest, part(nil_, taxable, 0.2, 0.4)
                    + part(taxable + min(shares, 500), taxable + shares, 0.0875, 0.3375))
            }
            XCTAssertEqual(NSDecimalNumber(decimal: got).doubleValue, cheapest, accuracy: 0.011, "\(interest) \(dividends)")
        }
    }

    func testAnAdditionalRatePayerHasNoSavingsAllowance() {
        let result = estimate(pay: 150_000, interest: 1_000, dividends: 1_000)
        XCTAssertEqual(result.savingsTax, 450)
        // £500 of dividends at nothing, £500 at 39.35%.
        XCTAssertEqual(result.dividendTax, pounds("196.75"))
    }

    func testDividendsCanMoveYouIntoTheHigherBandAndHalveTheSavingsAllowance() {
        let result = estimate(pay: 49_000, interest: 500, dividends: 5_000)
        XCTAssertEqual(result.savingsTax, 0)
        XCTAssertEqual(result.dividendTax, pounds("1451.25"))
        XCTAssertEqual(result.liability, pounds("8737.25"))
    }

    func testSavingsCountTowardsTheTaperOfThePersonalAllowance() {
        let result = estimate(pay: 100_000, interest: 2_000)
        XCTAssertEqual(result.personalAllowance, 11_570)
        XCTAssertEqual(result.adjustedNetIncome, 102_000)
    }

    func testReliefForIndianTaxIsTheSmallerOfTheTaxAllowedAndTheUKTaxItCauses() {
        let high = estimate(pay: 150_000, foreign: 1_000, foreignTax: 150)
        XCTAssertEqual(high.foreignRelief, 150)
        XCTAssertEqual(high.liability, 54_153 - 150)
        XCTAssertEqual(high.interest, 1_000)
        // Covered by the starting band, so no UK tax and nothing to relieve.
        let low = estimate(pay: 15_000, foreign: 500, foreignTax: 75)
        XCTAssertEqual(low.foreignRelief, 0)
        // UK tax on the slice is less than India took: only the UK tax is relieved.
        let part = estimate(pay: 60_000, foreign: 600, foreignTax: 90)
        XCTAssertEqual(part.savingsTax, 40)
        XCTAssertEqual(part.foreignRelief, 40)
        XCTAssertEqual(part.liability, estimate(pay: 60_000).liability)
    }

    func testReliefFeedsTheBalanceAndAdvancePayments() {
        let result = estimate(pay: 0, interest: 100_000, foreign: 20_000, foreignTax: 3_000)
        XCTAssertEqual(result.balance, result.liability)
        XCTAssertEqual(result.paymentOnAccount, TaxMoney.penceDown(result.liability / 2))
        XCTAssertEqual(result.foreignRelief, 3_000)
    }

    func testFinanceReliefIgnoresSavingsAndDividends() {
        var input = PersonInput()
        input.property = [.rent: 10_000, .financeCost: 5_000]
        input.ukInterest = 20_000
        let result = TaxCalculator.estimate(input)
        // The other income is within the personal allowance, so nothing is relievable.
        XCTAssertEqual(result.financeReduction, 0)
        XCTAssertEqual(result.financeCarriedForward, 5_000)
    }

    func testEnteredSavingsAndIndiaAccountsReachTheEstimateAndTheForms() {
        let year = TaxYear(startYear: 2025)
        var figures = YearFigures(person: .me, taxYear: "2025-26")
        XCTAssertTrue(figures.isBlank)
        figures.ukInterest = pounds("1200.90")
        figures.ukDividends = 800
        XCTAssertFalse(figures.isBlank)
        var india = IndiaBook()
        let account = IndiaAccount(id: "a", bank: .sbi, kind: .nro)
        india.save(account)
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 6, 30), kind: .interest, rupees: 100_000))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 6, 30), kind: .taxDeducted, rupees: 31_200))
        let book = PropertyBook(figures: [figures])
        var input = PersonInput.make(.me, ledger: PropertyLedger(), book: book, year: year, india: india)
        XCTAssertTrue(input.isMissingRate)
        XCTAssertEqual(input.foreignInterest, 0)
        india.setRate("2025-26", rupeesPerPound: 100)
        input = PersonInput.make(.me, ledger: PropertyLedger(), book: book, year: year, india: india)
        XCTAssertFalse(input.isMissingRate)
        XCTAssertEqual(input.foreignInterest, 1_000)
        XCTAssertEqual(input.foreignTax, 150)
        let pack = ReturnPack.make(.me, year: year, ledger: PropertyLedger(), book: book, india: india, today: TaxYear.day(2026, 11, 26))
        let main = Dictionary(uniqueKeysWithValues: pack.forms[0].entries.map { ($0.id, $0.value) })
        XCTAssertEqual(main["SA100.TR3.2"], .pounds(1_200))
        XCTAssertEqual(main["SA100.TR3.4"], .pounds(800))
        XCTAssertNotNil(ReturnLayout.placement(of: "SA100.TR3.2"))
        XCTAssertNotNil(ReturnLayout.placement(of: "SA100.TR3.4"))
    }

    func testSavedFiguresFromBeforeStillLoad() throws {
        let old = #"{"id":"x","person":"me","taxYear":"2025-26","losses":1,"financeCosts":0,"advancePaid":0,"giftAid":0,"isShared":false,"enteredBy":"me"}"#
        let figures = try SyncRecord.decoder().decode(YearFigures.self, from: Data(old.utf8))
        XCTAssertNil(figures.ukInterest)
    }
}
