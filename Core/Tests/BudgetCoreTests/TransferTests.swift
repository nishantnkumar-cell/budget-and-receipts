import XCTest
@testable import BudgetCore

final class TransferTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: d, hour: 12))! }

    private let current = BankAccount(name: "first direct")
    private let savings = BankAccount(name: "NatWest")
    private let amex = BankAccount(name: "Amex")

    private func tx(_ d: Int, _ merchant: String, _ amount: String, _ category: String, _ account: BankAccount?) -> BankTransaction {
        var transaction = BankTransaction(date: day(d), merchant: merchant, amount: money(amount), category: category, fingerprint: UUID().uuidString)
        transaction.accountID = account?.id
        return transaction
    }

    private func detect(_ transactions: [BankTransaction], names: [String] = ["NISHANT KUMAR", "SHWETA KUMAR"]) -> [String: TransferDetector.Change] {
        TransferDetector.detect(transactions, accounts: [current, savings, amex], names: names, calendar: calendar)
    }

    func testBothSidesOfATransferBetweenYourAccounts() {
        let out = tx(1, "OnLine Transaction PYMT FP 06", "-800", "Savings & investments", savings)
        let into = tx(2, "CR SOMEONE", "800", "Income", current)
        let found = detect([out, into], names: [])
        XCTAssertEqual(found[out.id]?.category, "Internal transfer")
        XCTAssertEqual(found[into.id]?.category, "Internal transfer")
    }

    func testPairsNeedDifferentAccountsAndCloseDates() {
        let sameAccount = [tx(1, "SHOP", "-50", "Shopping", current), tx(1, "SHOP REFUND", "50", "Shopping", current)]
        XCTAssertTrue(detect(sameAccount, names: []).isEmpty, "A refund in the same account isn't a transfer")
        let farApart = [tx(1, "X", "-500", "Shopping", current), tx(20, "Y", "500", "Income", savings)]
        XCTAssertTrue(detect(farApart, names: []).isEmpty)
        let pay = [tx(1, "X", "-500", "Shopping", current), tx(1, "ACME SALARY", "500", "Income", savings)]
        XCTAssertTrue(detect(pay, names: []).isEmpty, "Pay is never the other side of a transfer")
    }

    func testCardBillsFromTheBank() {
        let bills = [tx(3, "DD AMERICAN EXPRESS", "-926.55", "Shopping", current), tx(3, "DD HSBC CARD PYMT", "-1078.72", "Bills & utilities", current),
                     tx(3, "DD CAPITAL ONE", "-200.61", "Shopping", current)]
        XCTAssertEqual(Set(detect(bills).values.map(\.category)), ["Card payment"])
        let paired = [tx(3, "DD AMEX", "-100", "Shopping", current), tx(4, "PAYMENT RECEIVED - THANK YOU", "100", "Income", amex)]
        XCTAssertEqual(Set(detect(paired).values.map(\.category)), ["Card payment"])
    }

    func testYourOwnNamesTheWaysBanksWriteThem() {
        let rows = [tx(1, "CR KUMAR N NISHANT/FDACC", "3000", "Income", current), tx(2, "SO KUMAR N&S FAMILY", "-2500", "Shopping", nil),
                    tx(3, "CR FAMILY KUMAR S", "2500", "Income", nil), tx(4, "BP Mani Builder Nishant Hampton", "-1500", "Uncategorised", current),
                    tx(5, "HCL PAYROLL NISHANT KUMAR", "6000", "Income", current)]
        let found = detect(rows)
        XCTAssertEqual(found[rows[0].id]?.category, "Internal transfer")
        XCTAssertEqual(found[rows[1].id]?.category, "Internal transfer")
        XCTAssertEqual(found[rows[2].id]?.category, "Internal transfer")
        XCTAssertNil(found[rows[3].id], "A builder called Nishant isn't you")
        XCTAssertNil(found[rows[4].id], "Pay mentioning your name is still pay")
    }

    func testTopUpsAndSavings() {
        let rows = [tx(1, "MAS Revolut**2890 London", "-100", "Shopping", current), tx(2, "SO NS AND I 338149777", "-50", "Shopping", current),
                    tx(3, "SO NS&I 3272107262", "-150", "Shopping", current)]
        let found = detect(rows)
        XCTAssertEqual(found[rows[0].id]?.category, "Internal transfer")
        XCTAssertEqual(found[rows[1].id]?.category, "Savings & investments")
        XCTAssertEqual(found[rows[2].id]?.category, "Savings & investments")
    }

    func testYourOwnChoiceIsKeptAndDoneOnesAreLeftOut() {
        var chosen = tx(1, "DD AMERICAN EXPRESS", "-500", "Shopping", current)
        chosen.categoryChosen = true
        var done = tx(1, "DD CAPITAL ONE", "-50", "Card payment", current)
        done.subcategory = "Credit card repayment"
        XCTAssertTrue(detect([chosen, done]).isEmpty)
    }

    func testTransfersAndSavingsArentSpendingOrIncome() {
        let rows = [tx(1, "X", "-800", "Internal transfer", current), tx(1, "Y", "800", "Internal transfer", savings),
                    tx(2, "NS&I", "-50", "Savings & investments", current), tx(3, "TESCO", "-20", "Groceries", current)]
        let calculator = BudgetCalculator(calendar: calendar)
        XCTAssertEqual(calculator.spendingByCategory(rows, month: day(1)).values.reduce(0, +), 20)
        XCTAssertEqual(calculator.income(rows, month: day(1)), 0)
        XCTAssertFalse(FinanceCategories.budgetable.contains("Savings & investments"))
    }

    func testBillPaymentCodeIsntBPPetrol() {
        let categoriser = Categoriser(history: [], rules: RulesEngine.starterRules)
        XCTAssertNotEqual(categoriser.suggest(for: tx(1, "BP David Badminton Anmol", "-120", "Uncategorised", current))?.category, "Transport")
        XCTAssertEqual(categoriser.suggest(for: tx(1, "BP 4432 LONDON", "-60", "Uncategorised", current))?.category, "Transport")
        XCTAssertEqual(categoriser.suggest(for: tx(1, "BP ANDERSON CDA 8B CORBAN ROAD", "2904.30", "Uncategorised", current))?.category, "Income")
    }
}
