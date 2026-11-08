import XCTest
@testable import BudgetCore

final class LoggedPaymentTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: d, hour: 12))! }
    private func line(_ merchant: String, _ amount: String, day d: Int, id: String) -> BankTransaction {
        BankTransaction(date: day(d), merchant: merchant, amount: -money(amount), fingerprint: id)
    }

    func testApplePayTapJoinsItsStatementLine() {
        var tap = BankTransaction.logged(amount: money("4.85"), merchant: "Pret A Manger", card: "Visa ••1234", date: day(3))
        tap.category = "Eating out"
        tap.categoryChosen = true
        tap.tags = ["Work"]
        let statement = line("PRET A MANGER LONDON", "4.85", day: 5, id: "s1")
        let matches = LoggedPaymentMatcher.match([tap, statement], calendar: calendar)
        XCTAssertEqual(matches, [.init(logged: tap.id, statement: "s1")])
        let merged = LoggedPaymentMatcher.merged(statement: statement, logged: tap)
        XCTAssertEqual(merged.fingerprint, "s1")
        XCTAssertEqual(merged.date, day(5))
        XCTAssertEqual(merged.category, "Eating out")
        XCTAssertEqual(merged.tags, ["Work"])
    }

    func testTwoLinesOfTheSameAmountNeedTheShopToAgree() {
        let tap = BankTransaction.logged(amount: money("3.10"), merchant: "Costa", date: day(3))
        let pret = line("PRET A MANGER", "3.10", day: 4, id: "p")
        let costa = line("COSTA COFFEE", "3.10", day: 4, id: "c")
        XCTAssertEqual(LoggedPaymentMatcher.match([tap, pret, costa], calendar: calendar).first?.statement, "c")
        // Neither name agrees: it waits rather than guess.
        let other = BankTransaction.logged(amount: money("3.10"), merchant: "Apple Pay", date: day(3))
        XCTAssertTrue(LoggedPaymentMatcher.match([other, pret, costa], calendar: calendar).isEmpty)
    }

    func testOutsideTheWindowOrWrongAmountStaysSeparate() {
        let tap = BankTransaction.logged(amount: money("12.00"), merchant: "Boots", date: day(3))
        XCTAssertTrue(LoggedPaymentMatcher.match([tap, line("BOOTS", "12.00", day: 12, id: "late")], calendar: calendar).isEmpty)
        XCTAssertTrue(LoggedPaymentMatcher.match([tap, line("BOOTS", "12.50", day: 4, id: "other")], calendar: calendar).isEmpty)
        // A single line of that amount from another shop, days later, isn't assumed to be it.
        XCTAssertTrue(LoggedPaymentMatcher.match([tap, line("TESCO", "12.00", day: 8, id: "tesco")], calendar: calendar).isEmpty)
    }

    func testEachStatementLineTakesOneTap() {
        let first = BankTransaction.logged(amount: money("2.50"), merchant: "TfL", date: day(3))
        let second = BankTransaction.logged(amount: money("2.50"), merchant: "TfL", date: day(3))
        let matches = LoggedPaymentMatcher.match([first, second, line("TFL TRAVEL CH", "2.50", day: 4, id: "one")], calendar: calendar)
        XCTAssertEqual(matches.count, 1)
    }

    func testPaymentLoggedAbroadMatchesByShopAndIsNotSpendingYet() {
        var tap = BankTransaction.logged(amount: money("9.00"), merchant: "Cafe Nicola", date: day(3))
        tap.loggedCurrency = "EUR"
        tap.category = "Eating out"
        let statement = line("CAFE NICOLA LISBOA", "7.84", day: 5, id: "s")
        XCTAssertEqual(LoggedPaymentMatcher.match([tap, statement], calendar: calendar).first?.statement, "s")
        XCTAssertNil(BudgetCalculator(calendar: calendar).spendingByCategory([tap], month: day(1))["Eating out"])
    }
}

final class BudgetQuestionTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func facts() -> BudgetFacts {
        let month = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        let transactions = [
            BankTransaction(date: month, merchant: "TESCO STORES 123", amount: -money("45.20"), category: "Groceries", fingerprint: "a"),
            BankTransaction(date: month, merchant: "DISHOOM", amount: -money("62.00"), category: "Eating out", fingerprint: "b"),
        ]
        let budgets = [MonthlyBudget(category: "Groceries", limit: money("300"), month: month)]
        return BudgetFacts.make(transactions: transactions, budgets: budgets, month: month, calculator: BudgetCalculator(calendar: calendar),
                                safeToSpend: nil, bills: [], currency: "GBP")
    }

    func testFactsSheetHoldsExactFigures() {
        let sheet = facts().sheet
        XCTAssertTrue(sheet.contains("£107.20"), sheet)
        XCTAssertTrue(sheet.contains("Groceries: spent £45.20 so far; budget £300.00, £254.80 still left"), sheet)
        XCTAssertTrue(sheet.contains("Tesco Stores: £45.20, 1 visit"), sheet)
    }

    func testSimpleAnswersWithoutTheModel() {
        let facts = facts()
        XCTAssertEqual(facts.simpleAnswer(to: "How much have I spent on groceries?"), "You've spent £45.20 on Groceries in November 2026, with £254.80 left of £300.00.")
        XCTAssertEqual(facts.simpleAnswer(to: "dishoom?"), "You've spent £62.00 at Dishoom in November 2026, over 1 visit.")
        XCTAssertNotNil(facts.simpleAnswer(to: "What have I spent this month"))
        XCTAssertNil(facts.simpleAnswer(to: "Tell me a joke"))
    }
}

final class AffordQuestionTests: XCTestCase {
    func testAffordIsWorkedOutExactly() {
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))!
        let transactions = [BankTransaction(date: month, merchant: "DISHOOM", amount: -money("162.00"), category: "Eating out", fingerprint: "b")]
        let budgets = [MonthlyBudget(category: "Eating out", limit: money("120"), month: month)]
        let facts = BudgetFacts.make(transactions: transactions, budgets: budgets, month: month, calculator: BudgetCalculator(calendar: calendar),
                                     safeToSpend: nil, bills: [], currency: "GBP")
        XCTAssertEqual(facts.affordAnswer(to: "Can I afford a £50 dinner on eating out?"), "Not within the Eating out budget: it has £0.00 left this month.")
        XCTAssertTrue(facts.sheet.contains("over budget by £42.00"), facts.sheet)
        XCTAssertNil(facts.affordAnswer(to: "How much is left?"))
    }
}
