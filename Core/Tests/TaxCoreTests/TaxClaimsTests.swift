import BudgetCore
import XCTest
@testable import TaxCore

/// All figures are made up.
final class TaxClaimsTests: XCTestCase {
    private let year = TaxYear(startYear: 2025)
    private let today = TaxYear.day(2026, 11, 26)

    private func job(_ pay: Decimal, person: Person = .me, expenses: JobExpenses? = nil, atSource: Decimal = 0) -> TaxPay {
        var job = TaxPay(person: person, taxYear: "2025-26", employer: "Made Up Ltd \(person.rawValue)", taxablePay: pay,
                         taxDeducted: 0, reliefAtSourcePension: atSource)
        job.expenses = expenses
        return job
    }

    private func claims(_ book: PropertyBook, india: IndiaBook = IndiaBook()) -> [String: TaxClaim] {
        let list = TaxClaim.list(.me, year: year, ledger: PropertyLedger(), book: book, india: india, today: today)
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    private func amount(_ claim: TaxClaim?, _ label: String) -> Decimal? { claim?.lines.first { $0.label == label }?.amount }

    func testJobExpensesLowerTheBillAndReachTheEmploymentPage() {
        let book = PropertyBook(pay: [job(60_000, expenses: JobExpenses(travel: 100, subscriptions: 500))])
        let result = TaxCalculator.estimate(.make(.me, ledger: PropertyLedger(), book: book, year: year))
        XCTAssertEqual(result.jobExpenses, 600)
        XCTAssertEqual(result.liability, 11_432 - 240)
        let list = claims(book)
        XCTAssertEqual(list["subscriptions"]?.status, .claimed)
        XCTAssertEqual(list["subscriptions"]?.worth, 200)
        XCTAssertEqual(list["travel"]?.worth, 40)
        XCTAssertEqual(list["flatRate"]?.status, TaxClaim.Status.none)
        let pack = ReturnPack.make(.me, year: year, ledger: PropertyLedger(), book: book, today: today)
        let employment = pack.forms.first { $0.kind == .employment }!
        XCTAssertEqual(employment.entries.first { $0.id == "SA102.19" }?.value, .pounds(500))
        XCTAssertEqual(employment.entries.first { $0.id == "SA102.17" }?.value, .pounds(100))
        for entry in employment.entries { XCTAssertNotNil(ReturnLayout.placement(of: entry.id), entry.id) }
        XCTAssertEqual(pack.claims.count, list.count)
    }

    func testExpensesNeverExceedTheJobsOwnPay() {
        let book = PropertyBook(pay: [job(300, expenses: JobExpenses(other: 1_000)), job(60_000, person: .partner)])
        let input = PersonInput.make(.me, ledger: PropertyLedger(), book: book, year: year)
        XCTAssertEqual(input.jobExpenses.total, 300)
        XCTAssertTrue(ReturnPack.make(.me, year: year, ledger: PropertyLedger(), book: book).problems.contains { $0.contains("more than its pay") })
    }

    func testHigherRateReliefOnPensionAndGiftAidIsShown() {
        var figures = YearFigures(person: .me, taxYear: "2025-26")
        figures.giftAid = 1_000
        let list = claims(PropertyBook(pay: [job(70_000, atSource: 5_000)], figures: [figures]))
        XCTAssertEqual(list["reliefAtSource"]?.worth, 1_000)
        XCTAssertEqual(list["giftAid"]?.worth, 200)
    }

    func testEveryPoundOfIndianTaxIsAccountedFor() {
        var india = IndiaBook()
        india.save(IndiaAccount(id: "a", bank: .sbi, kind: .nro))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 6, 30), kind: .interest, rupees: 200_000))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 6, 30), kind: .taxDeducted, rupees: 62_400))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 8, 1), kind: .dividend, rupees: 100_000))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 8, 1), kind: .dividendTax, rupees: 20_800))
        india.setRate("2025-26", rupeesPerPound: 100)
        // Pay leaves most interest in the savings allowance at higher rate.
        let list = claims(PropertyBook(pay: [job(60_000)]), india: india)
        for id in ["reliefInterest", "reliefDividends"] {
            let claim = list[id]
            let taken = amount(claim, "Tax taken in India")!
            let parts = ["Relief given here", "Above the treaty rate: reclaim in India", "Not relieved: the UK tax on it is lower"]
                .reduce(Decimal(0)) { $0 + amount(claim, $1)! }
            XCTAssertEqual(parts, taken, id)
        }
        XCTAssertEqual(amount(list["reliefInterest"], "Tax taken in India"), 624)
        XCTAssertEqual(amount(list["reliefInterest"], "Above the treaty rate: reclaim in India"), 324)
        XCTAssertEqual(amount(list["reliefDividends"], "Relief given here"), 100)
        XCTAssertEqual(amount(list["reliefDividends"], "Above the treaty rate: reclaim in India"), 108)
    }

    func testTaxWithNoIncomeAgainstItIsStillAccountedFor() {
        var india = IndiaBook()
        india.save(IndiaAccount(id: "a", bank: .sbi, kind: .nro))
        india.save(IndiaAccount(id: "b", bank: .icici, kind: .nro))
        india.save(.manual(accountID: "a", date: TaxYear.day(2025, 6, 30), kind: .interest, rupees: 100_000))
        india.save(.manual(accountID: "b", date: TaxYear.day(2025, 6, 30), kind: .taxDeducted, rupees: 5_000))
        india.setRate("2025-26", rupeesPerPound: 100)
        let claim = claims(PropertyBook(pay: [job(60_000)]), india: india)["reliefInterest"]
        XCTAssertEqual(amount(claim, "Tax taken in India"), 50)
        XCTAssertEqual(amount(claim, "No income entered for this tax: check India Accounts"), 50)
        XCTAssertEqual(amount(claim, "Above the treaty rate: reclaim in India"), 0)
    }

    func testPensionSavingIsSplitBetweenAllowanceCarryForwardAndExcess() {
        var figures = YearFigures(person: .me, taxYear: "2025-26")
        figures.pension = PensionYear(paidIn: 80_000, sacrificed: 80_000, unused: 15_000)
        let claim = claims(PropertyBook(pay: [job(100_000)], figures: [figures]))["annualAllowance"]
        XCTAssertEqual(amount(claim, "Within this year's allowance"), 60_000)
        XCTAssertEqual(amount(claim, "Covered by allowance brought forward"), 15_000)
        XCTAssertEqual(amount(claim, "Above what's allowed"), 5_000)
        XCTAssertEqual(amount(claim, "Charge on the excess"), 2_000)
        XCTAssertEqual(claim?.status, .charge)
        XCTAssertEqual(claim?.worth, 6_000)
        let pack = ReturnPack.make(.me, year: year, ledger: PropertyLedger(), book: PropertyBook(pay: [job(100_000)], figures: [figures]),
                                   today: today)
        let answers = pack.forms.first { $0.kind == .main }!.entries
        XCTAssertTrue(answers.contains { $0.id == "SA100.TR2.9" })
        XCTAssertNotNil(ReturnLayout.placement(of: "SA100.TR2.9"))
    }

    func testCarryForwardIsValuedEvenWhenTheSchemePaysTheCharge() {
        var figures = YearFigures(person: .me, taxYear: "2025-26")
        figures.pension = PensionYear(paidIn: 90_000, sacrificed: 90_000, unused: 20_000, schemePays: 100_000)
        let claim = claims(PropertyBook(pay: [job(100_000)], figures: [figures]))["annualAllowance"]
        XCTAssertEqual(claim?.worth, 8_000)
        XCTAssertEqual(claim?.worthText, "carry forward saves \(TaxMoney.format(8_000))")
    }

    func testEachUnequalPropertyShowsItsOwnForm17State() {
        let book = PropertyBook(properties: [
            RentalProperty(id: "a", name: "Made Up One", myShare: Decimal(3) / 4),
            RentalProperty(id: "b", name: "Made Up Two", myShare: Decimal(3) / 4, form17From: TaxYear.day(2025, 5, 1)),
            RentalProperty(id: "c", name: "Made Up Three", form17From: TaxYear.day(2025, 5, 1))
        ])
        let list = claims(book)
        XCTAssertEqual(list["form17|a"]?.status, .open)
        XCTAssertEqual(list["form17|b"]?.status, .automatic)
        XCTAssertNil(list["form17|c"])
    }

    func testPayOfExactlyTheAllowanceIsNotCalledHigherRate() {
        XCTAssertEqual(claims(PropertyBook(pay: [job(12_570)]))["marriage"]?.status, .yourself)
    }

    func testClaimingPensionReliefIsValuedWithoutChangingTheAllowance() {
        var figures = YearFigures(person: .me, taxYear: "2025-26")
        figures.pension = PensionYear(paidIn: 60_000)
        // £20,000 widens both bands: £4,000 at the higher rate and £1,000 at the additional.
        XCTAssertEqual(claims(PropertyBook(pay: [job(250_000, atSource: 20_000)], figures: [figures]))["reliefAtSource"]?.worth, 5_000)
    }

    func testDeadlinesFollowTheDate() {
        func list(_ date: Date) -> [String: TaxClaim] {
            Dictionary(uniqueKeysWithValues: TaxClaim.list(.me, year: TaxYear(startYear: 2026), ledger: PropertyLedger(),
                                                           book: PropertyBook(), today: date).map { ($0.id, $0) })
        }
        let later = list(TaxYear.day(2027, 5, 1))
        XCTAssertEqual(later["earlier"]?.title, "Claims for 2023-24 close on 5 April 2028")
        XCTAssertTrue(later["marriage"]!.rule.contains("6 April 2023"))
        XCTAssertEqual(list(TaxYear.day(2027, 4, 5))["earlier"]?.title, "Claims for 2022-23 close on 5 April 2027")
    }

    func testMarriageAllowanceIsRaisedOnlyWhenTheFiguresAllowIt() {
        let eligible = claims(PropertyBook(pay: [job(30_000), job(8_000, person: .partner)]))["marriage"]
        XCTAssertEqual(eligible?.status, .open)
        XCTAssertEqual(eligible?.worth, 252)
        XCTAssertEqual(claims(PropertyBook(pay: [job(60_000), job(8_000, person: .partner)]))["marriage"]?.status, .notDue)
        // With nothing for a partner it can't be ruled out.
        XCTAssertEqual(claims(PropertyBook(pay: [job(30_000)]))["marriage"]?.status, .yourself)
        XCTAssertEqual(claims(PropertyBook(pay: [job(90_000)]))["marriage"]?.status, .notDue)
        let giving = claims(PropertyBook(pay: [job(8_000), job(30_000, person: .partner)]))["marriage"]
        XCTAssertEqual(giving?.status, .open)
        XCTAssertNil(giving?.worth)
    }

    func testTheEarliestOpenYearAndWhatTheAppLeavesOutAreListed() {
        let list = claims(PropertyBook(pay: [job(30_000)]))
        XCTAssertEqual(list["earlier"]?.title, "Claims for 2022-23 close on 5 April 2027")
        for id in ["gains", "rentARoom", "investment", "otherReliefs", "blind", "giftCarry", "otherPension"] { XCTAssertEqual(list[id]?.status, .yourself, id) }
        XCTAssertNil(list["expenses"])
    }

    private func letting(rent: Decimal, repairs: Decimal, interest: Decimal) -> (PropertyBook, PropertyLedger) {
        let property = RentalProperty(id: "p", name: "Made Up Flat", myShare: 1)
        var ledger = PropertyLedger()
        ledger.lines = [(PropertyCategory.rent, rent), (.repairs, repairs), (.financeCost, interest)].map {
            PropertyLedger.Line(propertyID: "p", date: TaxYear.day(2025, 6, 1), source: "made up", category: $0.0, amount: $0.1)
        }
        return (PropertyBook(properties: [property], pay: [job(40_000)]), ledger)
    }

    func testLettingClaimsAreValuedAndTheAllowanceIsOnlySuggestedWhenCheaper() {
        func list(_ book: PropertyBook, _ ledger: PropertyLedger) -> [String: TaxClaim] {
            Dictionary(uniqueKeysWithValues: TaxClaim.list(.me, year: year, ledger: ledger, book: book, today: today).map { ($0.id, $0) })
        }
        let costly = letting(rent: 10_000, repairs: 2_000, interest: 3_000)
        let claims = list(costly.0, costly.1)
        XCTAssertEqual(claims["expenses"]?.worth, 400)
        XCTAssertEqual(claims["finance"]?.worth, 600)
        XCTAssertEqual(claims["propertyAllowance"]?.status, .notDue)
        let cheap = letting(rent: 10_000, repairs: 200, interest: 0)
        let other = list(cheap.0, cheap.1)
        XCTAssertEqual(other["propertyAllowance"]?.status, .open)
        // £800 more taken off at 20%.
        XCTAssertEqual(other["propertyAllowance"]?.worth, 160)
    }
}
