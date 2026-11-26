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

    func testTheBestSplitCanFallWhereIncomeCrossesIntoTheHigherBand() {
        // £12,300 against interest leaves it exactly filling the basic band.
        XCTAssertEqual(estimate(interest: 50_000, dividends: 2_500).liability, pounds("7023.87"))
        XCTAssertEqual(estimate(pay: 9_970, interest: 40_000, dividends: 20_000).liability, 12_920)
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

    // MARK: Dividends from India

    func testIndianDividendsShareTheAllowanceAndGetNoMoreThanTheUKTaxAsRelief() {
        var input = PersonInput()
        input.pay = 60_000
        input.dividends = 500
        input.foreignDividends = 1_000
        input.foreignDividendTax = 100
        let result = TaxCalculator.estimate(input)
        XCTAssertEqual(result.dividends, 1_500)
        XCTAssertEqual(result.dividendTax, pounds("337.50"))
        XCTAssertEqual(result.foreignRelief, 100)
        XCTAssertEqual(result.liability, 11_432 + pounds("337.50") - 100)
        // Within the allowance, there's no UK tax to relieve.
        input.dividends = 0
        input.foreignDividends = 400
        XCTAssertEqual(TaxCalculator.estimate(input).foreignRelief, 0)
    }

    func testReliefOnInterestAndDividendsNeverCountsTheSameTaxTwice() {
        var input = PersonInput()
        input.pay = 49_000
        input.foreignInterest = 2_000
        input.foreignTax = 300
        input.foreignDividends = 3_000
        input.foreignDividendTax = 300
        let result = TaxCalculator.estimate(input)
        var without = input
        without.foreignInterest = 0
        without.foreignDividends = 0
        XCTAssertLessThanOrEqual(result.foreignRelief, result.liability + result.foreignRelief - TaxCalculator.estimate(without).liability)
        XCTAssertEqual(result.foreignRelief, 600)
    }

    func testIndiaDividendsReachTheEstimateAndTheForeignPages() {
        let year = TaxYear(startYear: 2025)
        var india = IndiaBook()
        india.save(IndiaAccount(id: "a", bank: .icici, kind: .nro))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 8, 1), kind: .dividend, rupees: 100_000))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 8, 1), kind: .dividendTax, rupees: 20_000))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 6, 30), kind: .interest, rupees: 50_000))
        var input = PersonInput.make(.me, ledger: PropertyLedger(), book: PropertyBook(), year: year, india: india)
        XCTAssertTrue(input.isMissingRate)
        india.setRate("2025-26", rupeesPerPound: 100)
        input = PersonInput.make(.me, ledger: PropertyLedger(), book: PropertyBook(), year: year, india: india)
        XCTAssertEqual(input.foreignDividends, 1_000)
        // India took 20%; only the treaty's 10% is relieved.
        XCTAssertEqual(input.foreignDividendTax, 100)
        XCTAssertEqual(input.foreignInterest, 500)
        let pack = ReturnPack.make(.me, year: year, ledger: PropertyLedger(), book: PropertyBook(), india: india,
                                   today: TaxYear.day(2026, 11, 26))
        let foreign = pack.forms.first { $0.kind == .foreign }!
        let values = Dictionary(uniqueKeysWithValues: foreign.entries.map { ($0.id, $0.value) })
        XCTAssertEqual(values["SA106.DB1"], .pounds(1_000))
        XCTAssertEqual(values["SA106.DC1"], .pounds(100))
        XCTAssertEqual(values["SA106.6"], .pounds(1_000))
        // The untaxed interest joins it there rather than going on the main return.
        XCTAssertEqual(values["SA106.B1"], .pounds(500))
        XCTAssertEqual(values["SA106.4"], .pounds(500))
        XCTAssertFalse(pack.forms.contains { $0.entries.contains { $0.id == "SA100.TR3.3" } })
        for entry in pack.forms.flatMap(\.entries) { XCTAssertNotNil(ReturnLayout.placement(of: entry.id), entry.id) }
        XCTAssertTrue(pack.checks.contains { $0.contains("10%") })
        let csv = IndiaReport.make(india, year: year, person: .me).csv(india)
        XCTAssertTrue(csv.contains("Dividends GBP"))
        XCTAssertTrue(csv.contains("Dividend, before tax"))
    }

    func testSmallUntaxedForeignDividendsGoOnTheMainReturn() {
        var india = IndiaBook()
        india.save(IndiaAccount(id: "a", bank: .sbi, kind: .nro))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 8, 1), kind: .dividend, rupees: 40_000))
        india.setRate("2025-26", rupeesPerPound: 100)
        let pack = ReturnPack.make(.me, year: TaxYear(startYear: 2025), ledger: PropertyLedger(), book: PropertyBook(), india: india)
        XCTAssertEqual(pack.forms.first?.entries.first { $0.id == "SA100.TR3.6" }?.value, .pounds(400))
        XCTAssertFalse(pack.forms.contains { $0.kind == .foreign })
    }

    // MARK: Pension annual allowance

    private func pension(pay: Decimal, paidIn: Decimal, sacrificed: Decimal = 0, unused: Decimal = 0, schemePays: Decimal = 0,
                         atSource: Decimal = 0) -> TaxEstimate {
        var input = PersonInput()
        input.pay = pay
        input.pensionPaidIn = paidIn
        input.pensionSacrificed = sacrificed
        input.pensionUnused = unused
        input.pensionSchemePays = schemePays
        input.reliefAtSourcePension = atSource
        return TaxCalculator.estimate(input)
    }

    func testSavingAboveTheAllowanceIsTaxedOnTopOfIncome() {
        let none = pension(pay: 100_000, paidIn: 60_000, sacrificed: 60_000)
        XCTAssertEqual(none.pensionAllowance, 60_000)
        XCTAssertEqual(none.pensionCharge, 0)
        let over = pension(pay: 100_000, paidIn: 70_000, sacrificed: 70_000)
        XCTAssertEqual(over.pensionExcess, 10_000)
        XCTAssertEqual(over.pensionCharge, 4_000)
        XCTAssertEqual(over.liability, none.liability + 4_000)
        // Carried forward allowance covers it; the scheme can pay part of what's left.
        XCTAssertEqual(pension(pay: 100_000, paidIn: 70_000, unused: 10_000).pensionCharge, 0)
        let paid = pension(pay: 100_000, paidIn: 70_000, schemePays: 3_000)
        XCTAssertEqual(paid.pensionSchemePaid, 3_000)
        XCTAssertEqual(paid.liability, none.liability + 1_000)
        XCTAssertEqual(pension(pay: 100_000, paidIn: 70_000, schemePays: 9_000).liability, none.liability)
        // Across a band edge: £3,000 of the excess at 20% and £3,000 at 40%.
        let straddling = pension(pay: 47_270, paidIn: 66_000)
        XCTAssertEqual(straddling.pensionCharge, 600 + 1_200)
    }

    func testHighIncomesGetASmallerAllowance() {
        // Threshold income £230,000 + £20,000 sacrificed; adjusted £230,000 + £50,000.
        let result = pension(pay: 230_000, paidIn: 50_000, sacrificed: 20_000)
        XCTAssertEqual(result.pensionAllowance, 50_000)
        XCTAssertEqual(result.pensionExcess, 0)
        let more = pension(pay: 300_000, paidIn: 60_000)
        XCTAssertEqual(more.pensionAllowance, 10_000)
        XCTAssertEqual(more.pensionCharge, 22_500)
        // Under the threshold, however much is paid in, the allowance isn't reduced.
        XCTAssertEqual(pension(pay: 190_000, paidIn: 120_000).pensionAllowance, 60_000)
        // Salary sacrifice counts towards the threshold.
        XCTAssertEqual(pension(pay: 190_000, paidIn: 80_000, sacrificed: 20_000).pensionAllowance, 55_000)
        // Relief-at-source saving is taken off the threshold and not counted twice above it.
        XCTAssertEqual(pension(pay: 280_000, paidIn: 20_000, atSource: 20_000).pensionAllowance, 50_000)
    }

    func testThePensionChargeAndFiguresReachTheForm() {
        var figures = YearFigures(person: .me, taxYear: "2025-26")
        figures.pension = PensionYear(paidIn: 70_000, sacrificed: 70_000, schemePays: 1_000)
        XCTAssertFalse(figures.isBlank)
        let job = TaxPay(person: .me, taxYear: "2025-26", employer: "Made Up Umbrella", taxablePay: 100_000, taxDeducted: 27_432)
        let pack = ReturnPack.make(.me, year: TaxYear(startYear: 2025), ledger: PropertyLedger(),
                                   book: PropertyBook(pay: [job], figures: [figures]))
        let form = pack.forms.first { $0.kind == .additional }!
        XCTAssertEqual(form.entries.map(\.value), [.pounds(10_000), .pounds(1_000)])
        for entry in form.entries { XCTAssertNotNil(ReturnLayout.placement(of: entry.id), entry.id) }
    }
}

