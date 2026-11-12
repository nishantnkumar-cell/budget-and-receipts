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

    private func detect(_ transactions: [BankTransaction], names: [String] = ["NEIL PATEL", "SARA PATEL"]) -> [String: TransferDetector.Change] {
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
        let rows = [tx(1, "CR PATEL N NEIL/FDACC", "3000", "Income", current), tx(2, "SO PATEL N&S FAMILY", "-2500", "Shopping", nil),
                    tx(3, "CR FAMILY PATEL S", "2500", "Income", nil), tx(4, "BP Ace Builder Neil Smith", "-1500", "Uncategorised", current),
                    tx(5, "ACME PAYROLL NEIL PATEL", "6000", "Income", current)]
        let found = detect(rows)
        XCTAssertEqual(found[rows[0].id]?.category, "Internal transfer")
        XCTAssertEqual(found[rows[1].id]?.category, "Internal transfer")
        XCTAssertEqual(found[rows[2].id]?.category, "Internal transfer")
        XCTAssertNil(found[rows[3].id], "A builder called Neil isn't you")
        XCTAssertNil(found[rows[4].id], "Pay mentioning your name is still pay")
    }

    func testTopUpsAndSavings() {
        let rows = [tx(1, "MAS Revolut**1234 London", "-100", "Shopping", current), tx(2, "SO NS AND I 123456789", "-50", "Shopping", current),
                    tx(3, "SO NS&I 1234567890", "-150", "Shopping", current)]
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
    // MARK: Real money that only looked like a transfer

    func testCardPaymentToAShopIsSpending() {
        let rows = [tx(3, "CARD PAYMENT TO TESCO STORES 3297", "-12.40", "Groceries", current),
                    tx(4, "Card Payment to AMAZON.CO.UK", "-25.99", "Shopping", current)]
        XCTAssertTrue(detect(rows).isEmpty, "Santander writes debit card shopping as CARD PAYMENT TO")
    }

    func testPhoneAndOysterTopUpsAreSpending() {
        let rows = [tx(1, "VODAFONE TOP UP", "-10", "Bills & utilities", current), tx(2, "OYSTER TOP-UP", "-20", "Transport", current),
                    tx(3, "EE TOPUP 0791", "-15", "Uncategorised", current)]
        XCTAssertTrue(detect(rows).isEmpty)
    }

    func testPaymentReceivedIsACardBillOnlyOnACard() {
        let fromSomeone = tx(1, "FASTER PAYMENT RECEIVED FROM A SMITH", "50", "Uncategorised", current)
        let onCard = tx(2, "PAYMENT RECEIVED", "400", "Uncategorised", amex)
        let thanks = tx(3, "PAYMENT RECEIVED - THANK YOU", "300", "Uncategorised", nil)
        let found = detect([fromSomeone, onCard, thanks])
        XCTAssertNil(found[fromSomeone.id], "Money from someone else into a current account")
        XCTAssertEqual(found[onCard.id]?.category, "Card payment")
        XCTAssertEqual(found[thanks.id]?.category, "Card payment")
    }

    func testSomeoneWithYourInitialAndSurnameIsntYou() {
        let plumber = tx(1, "FPO N PATEL PLUMBING", "-120", "Uncategorised", current)
        let aunt = tx(2, "S PATEL BIRTHDAY", "50", "Uncategorised", current)
        let joint = tx(3, "SO PATEL N&S", "-500", "Uncategorised", current)
        let found = detect([plumber, aunt, joint])
        XCTAssertNil(found[plumber.id], "N PATEL is how a payee you typed reads")
        XCTAssertNil(found[aunt.id])
        XCTAssertEqual(found[joint.id]?.category, "Internal transfer", "Surname then initials is how banks print a holder")
    }

    func testUnrelatedEqualAmountsInTwoAccountsArentPaired() {
        let shop = tx(1, "TESCO STORES 3297", "-30", "Groceries", current)
        let paidBack = tx(2, "A SMITH DINNER", "30", "Uncategorised", savings)
        XCTAssertTrue(detect([shop, paidBack], names: []).isEmpty, "A purchase isn't cancelled by an unrelated credit")
        let moved = tx(1, "TFR TO SAVINGS", "-30", "Shopping", current)
        let arrived = tx(2, "FROM CURRENT ACCOUNT", "30", "Shopping", savings)
        let found = detect([moved, arrived], names: [])
        XCTAssertEqual(found[moved.id]?.category, "Internal transfer", "Transfer wording on one side is enough")
        XCTAssertEqual(found[arrived.id]?.category, "Internal transfer")
    }

    func testOldStarterRulesAreUpdatedUnlessYouChangedThem() {
        let old = RulesEngine.retiredStarterRules
        var edited = old[1]
        edited.conditions[0].value = "REVOLUT, WISE"
        let refreshed = RulesEngine.refreshingStarterRules([old[0], edited])
        XCTAssertEqual(refreshed[0].conditions, RulesEngine.starterRules.first { $0.id == old[0].id }?.conditions)
        XCTAssertEqual(refreshed[1].conditions, edited.conditions, "Your own change stays")
        let categoriser = Categoriser(history: [], rules: refreshed)
        XCTAssertNotEqual(categoriser.suggest(for: tx(1, "FASTER PAYMENT RECEIVED FROM A SMITH", "50", "Uncategorised", current))?.category, "Card payment")
        XCTAssertEqual(categoriser.suggest(for: tx(1, "PAYMENT RECEIVED - THANK YOU", "50", "Uncategorised", amex))?.category, "Card payment")
    }
    // MARK: Between the two of you, and cards not imported

    func testTransferToYourPartnersAccountIsBetweenYou() {
        var hers = BankAccount(name: "Sara first direct")
        hers.owner = .partner
        var joint = BankAccount(name: "Joint")
        joint.owner = .shared
        let toHer = tx(1, "OBP SARA PATEL", "-200", "Uncategorised", current)
        var arrived = tx(1, "CR PATEL N", "200", "Uncategorised", nil)
        arrived.accountID = hers.id
        let toJoint = tx(5, "SO JOINT ACCOUNT", "-500", "Uncategorised", current)
        var intoJoint = tx(5, "CR PATEL N", "500", "Uncategorised", nil)
        intoJoint.accountID = joint.id
        let found = TransferDetector.detect([toHer, arrived, toJoint, intoJoint], accounts: [current, hers, joint], names: ["NEIL PATEL", "SARA PATEL"], calendar: calendar)
        XCTAssertEqual(found[toHer.id]?.subcategory, "Between you")
        XCTAssertEqual(found[arrived.id]?.subcategory, "Between you")
        XCTAssertEqual(found[toJoint.id]?.subcategory, "Between accounts", "Paying into the joint account isn't settling up")
    }

    func testCardBillWithNoCardStatementIsFlagged() {
        let bill = tx(3, "DD AMERICAN EXPRESS", "-640", "Card payment", current)
        let paid = tx(4, "DD MBNA", "-100", "Card payment", current)
        let mbnaAccount = BankAccount(name: "MBNA card")
        var arrived = tx(5, "PAYMENT RECEIVED", "100", "Card payment", nil)
        arrived.accountID = mbnaAccount.id
        let missing = TransferDetector.untrackedCardBills([bill, paid, arrived], accounts: [current, mbnaAccount], since: day(1), calendar: calendar)
        XCTAssertEqual(missing.map(\.id), [bill.id], "The MBNA statement is imported; the Amex one isn't")
        XCTAssertTrue(TransferDetector.untrackedCardBills([bill], accounts: [current], since: day(10), calendar: calendar).isEmpty, "Older bills are left alone")
    }
}
