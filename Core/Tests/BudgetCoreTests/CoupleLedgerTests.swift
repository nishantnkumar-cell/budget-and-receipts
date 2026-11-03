import XCTest
@testable import BudgetCore

final class CoupleLedgerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private var october: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))! }

    private func tx(
        _ amount: String,
        _ category: String = "Groceries",
        merchant: String = "M",
        owner: MoneyOwner? = nil,
        paidBy: Person? = nil,
        splits: [TransactionSplit] = []
    ) -> BankTransaction {
        BankTransaction(date: october, merchant: merchant, amount: money(amount), category: category, fingerprint: UUID().uuidString, splits: splits, owner: owner, paidBy: paidBy)
    }

    private func ledger(myShare: String = "0.5", rules: [OwnerRule] = [], defaultOwner: MoneyOwner = .mine) -> CoupleLedger {
        CoupleLedger(settings: CoupleSettings(partnerName: "Sam", myShare: money(myShare), rules: rules, defaultOwner: defaultOwner), calculator: BudgetCalculator(calendar: calendar))
    }

    // MARK: Whose money

    func testOwnerSetOnTheTransactionWinsOverRules() {
        let ledger = ledger(rules: [OwnerRule(match: .category("Groceries"), owner: .shared)])
        XCTAssertEqual(ledger.owner(of: tx("-10.00", owner: .partner)), .partner)
        XCTAssertEqual(ledger.owner(of: tx("-10.00")), .shared)
        XCTAssertEqual(ledger.ruleOwner(of: tx("-10.00", owner: .partner)), .shared, "What Automatic would pick")
    }

    func testMerchantRuleBeatsCategoryRuleWhateverTheOrder() {
        let ledger = ledger(rules: [
            OwnerRule(match: .category("Subscriptions"), owner: .shared),
            OwnerRule(match: .merchant("netflix"), owner: .mine)
        ])
        XCTAssertEqual(ledger.owner(of: tx("-10.99", "Subscriptions", merchant: "NETFLIX.COM")), .mine)
        XCTAssertEqual(ledger.owner(of: tx("-5.99", "Subscriptions", merchant: "Spotify")), .shared)
    }

    func testUnmatchedTransactionsUseTheDefaultOwner() {
        XCTAssertEqual(ledger().owner(of: tx("-1.00")), .mine)
        XCTAssertEqual(ledger(defaultOwner: .shared).owner(of: tx("-1.00")), .shared)
    }

    func testBlankMerchantRuleMatchesNothing() {
        XCTAssertEqual(ledger(rules: [OwnerRule(match: .merchant("  "), owner: .partner)]).owner(of: tx("-1.00")), .mine)
    }

    // MARK: Shares

    func testSharesForEachView() {
        let ledger = ledger(myShare: "0.6")
        XCTAssertEqual(ledger.share(of: .shared, for: .me), money("0.6"))
        XCTAssertEqual(ledger.share(of: .shared, for: .partner), money("0.4"))
        XCTAssertEqual(ledger.share(of: .shared, for: .together), 1)
        XCTAssertEqual(ledger.share(of: .partner, for: .me), 0)
        XCTAssertEqual(ledger.share(of: .mine, for: .me), 1)
    }

    func testShareOutsideZeroToOneIsClamped() {
        XCTAssertEqual(ledger(myShare: "1.5").share(of: .shared, for: .partner), 0)
        XCTAssertEqual(ledger(myShare: "-1").share(of: .shared, for: .me), 0)
    }

    func testIncomeBasedShare() {
        XCTAssertEqual(CoupleSettings.share(myIncome: money("3000"), partnerIncome: money("2000")), money("0.6"))
        XCTAssertEqual(CoupleSettings.share(myIncome: 0, partnerIncome: 0), money("0.5"))
    }

    // MARK: Me / Partner / Together

    func testMeViewCountsMineAndMyHalfOfShared() {
        let ledger = ledger()
        let all = [tx("-40.00", owner: .shared), tx("-10.00", owner: .mine), tx("-25.00", owner: .partner)]
        let spent = ledger.calculator.spendingByCategory(ledger.transactions(all, for: .me), month: october)
        XCTAssertEqual(spent, ["Groceries": money("30.00")])
        let partner = ledger.calculator.spendingByCategory(ledger.transactions(all, for: .partner), month: october)
        XCTAssertEqual(partner, ["Groceries": money("45.00")])
        let together = ledger.calculator.spendingByCategory(ledger.transactions(all, for: .together), month: october)
        XCTAssertEqual(together, ["Groceries": money("75.00")])
    }

    func testSplitsKeepTheirOwnOwner() {
        let splits = [
            TransactionSplit(label: "Food", category: "Groceries", amount: money("30.00"), owner: .shared),
            TransactionSplit(label: "Shampoo", category: "Health", amount: money("6.00"), owner: .partner),
            TransactionSplit(label: "Socks", category: "Shopping", amount: money("4.00"))
        ]
        let ledger = ledger()
        let mine = ledger.transactions([tx("-40.00", "Uncategorised", owner: .mine, splits: splits)], for: .me)
        XCTAssertEqual(mine.first?.amount, money("-19.00"))
        XCTAssertEqual(ledger.calculator.spendingByCategory(mine, month: october), ["Groceries": money("15.00"), "Shopping": money("4.00")])
    }

    func testViewLeavesOutTransactionsWithNoShare() {
        XCTAssertTrue(ledger().transactions([tx("-25.00", owner: .partner)], for: .me).isEmpty)
    }

    // MARK: Who owes whom

    func testIPaySharedCostPartnerOwesHalf() {
        let balance = ledger().balance([tx("-50.00", owner: .shared)])
        XCTAssertEqual(balance.amount, money("25.00"))
        XCTAssertEqual(balance.debtor, .partner)
        XCTAssertEqual(balance.amountOwed, money("25.00"))
    }

    func testPaymentsBothWaysNetOff() {
        let balance = ledger().balance([tx("-50.00", owner: .shared), tx("-30.00", owner: .shared, paidBy: .partner)])
        XCTAssertEqual(balance.amount, money("10.00"))
    }

    func testPayingForTheOtherPersonsThingsIsOwedInFull() {
        let ledger = ledger()
        XCTAssertEqual(ledger.balance([tx("-20.00", owner: .partner)]).amount, money("20.00"))
        XCTAssertEqual(ledger.balance([tx("-20.00", owner: .mine, paidBy: .partner)]).amount, money("-20.00"))
        XCTAssertEqual(ledger.balance([tx("-20.00", owner: .mine)]).amount, 0)
    }

    func testUnevenShareUsesTheirPart() {
        XCTAssertEqual(ledger(myShare: "0.6").balance([tx("-100.00", owner: .shared)]).amount, money("40.00"))
    }

    func testRefundReversesWhatWasOwed() {
        let balance = ledger().balance([tx("-50.00", owner: .shared), tx("20.00", owner: .shared)])
        XCTAssertEqual(balance.amount, money("15.00"))
    }

    func testIncomeAndTransfersAreNotShared() {
        let balance = ledger(defaultOwner: .shared).balance([tx("2000.00", "Income"), tx("-300.00", "Internal transfer"), tx("-100.00", "Card payment")])
        XCTAssertEqual(balance.amount, 0)
        XCTAssertNil(balance.debtor)
    }

    func testSplitReceiptOwesOnlyTheSharedAndPartnerParts() {
        let splits = [
            TransactionSplit(label: "Food", category: "Groceries", amount: money("30.00"), owner: .shared),
            TransactionSplit(label: "Shampoo", category: "Health", amount: money("6.00"), owner: .partner),
            TransactionSplit(label: "Socks", category: "Shopping", amount: money("4.00"))
        ]
        XCTAssertEqual(ledger().balance([tx("-40.00", "Uncategorised", owner: .mine, splits: splits)]).amount, money("21.00"))
    }

    func testSettlingUpClearsTheBalance() {
        let settled = ledger().balance([tx("-50.00", owner: .shared)], settlements: [Settlement(date: october, from: .partner, amount: money("25.00"))])
        XCTAssertEqual(settled.amount, 0)
        XCTAssertNil(settled.debtor)
    }

    func testIOweWhenPartnerPaidMore() {
        let balance = ledger().balance([tx("-80.00", owner: .shared, paidBy: .partner)])
        XCTAssertEqual(balance.debtor, .me)
        XCTAssertEqual(balance.amountOwed, money("40.00"))
    }

    func testOddPennyRoundsToTheNearestPenny() {
        // Half of 3.33 is 1.665; only whole pennies can change hands.
        let balance = ledger().balance([tx("-3.33", owner: .shared)])
        XCTAssertEqual(balance.amount, money("1.665"))
        XCTAssertEqual(balance.rounded, money("1.66"))
        XCTAssertEqual(balance.amountOwed, money("1.66"))
    }

    // MARK: Saved data

    func testTransactionsSavedBeforeCouplesStillLoad() throws {
        let old = #"{"date":0,"merchant":"Shop","description":"","amount":-5,"category":"Groceries","fingerprint":"f1","splits":[{"id":"9F8E7D6C-5B4A-3928-1706-F5E4D3C2B1A0","label":"Milk","category":"Groceries","amount":5}]}"#
        let transaction = try JSONDecoder().decode(BankTransaction.self, from: Data(old.utf8))
        XCTAssertNil(transaction.owner)
        XCTAssertNil(transaction.paidBy)
        XCTAssertNil(transaction.splits.first?.owner)
    }

    func testSettingsRoundTrip() throws {
        let settings = CoupleSettings(partnerName: "Sam", myShare: money("0.6"), rules: [OwnerRule(match: .merchant("Tesco"), owner: .shared)])
        let decoded = try JSONDecoder().decode(CoupleSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testReceiptItemOwnerCarriesIntoTheDraft() {
        var editor = ReceiptDraftEditor(merchant: "Shop", receiptTotal: money("6.00"), items: [ReceiptLineItem(description: "Shampoo", total: money("6.00"), category: "Health", confidence: 1)])
        editor.setOwner(editor.items[0].id, .partner)
        XCTAssertEqual(editor.makeDraft(reviewed: true).proposedSplits.first?.owner, .partner)
    }
    // MARK: Joint accounts and budgets per person

    func testJointAccountSpendingLeavesYouSquare() {
        var ledger = ledger(myShare: "0.6")
        let joint = UUID(), hers = UUID()
        ledger.accountOwners = [joint: .shared, hers: .partner]
        var food = tx("-100.00", owner: .shared)
        food.accountID = joint
        XCTAssertEqual(ledger.balance([food]).amount, 0, "The joint pot paid for something shared")
        var mine = tx("-50.00", owner: .mine)
        mine.accountID = joint
        XCTAssertEqual(ledger.balance([mine]).amount, money("-20"), "Partner's 40% of the joint money paid for my thing")
        var hersShared = tx("-100.00", owner: .shared)
        hersShared.accountID = hers
        XCTAssertEqual(ledger.balance([hersShared]).amount, money("-60"), "Her account paid, so I owe my 60%")
        XCTAssertEqual(ledger.balance([tx("-100.00", owner: .shared)]).amount, money("40"), "My account paid, so she owes her 40%")
    }

    func testBudgetsForOnePersonAreTheirShare() {
        let ledger = ledger(myShare: "0.6", rules: [OwnerRule(match: .category("Health"), owner: .mine)])
        let budgets = [MonthlyBudget(category: "Groceries", limit: 400, month: october), MonthlyBudget(category: "Health", limit: 50, month: october)]
        XCTAssertEqual(ledger.budgets(budgets, for: .me).map(\.limit), [240, 50])
        XCTAssertEqual(ledger.budgets(budgets, for: .partner).map(\.limit), [160, 0])
        XCTAssertEqual(ledger.budgets(budgets, for: .together).map(\.limit), [400, 50])
    }
    func testBankTransferBetweenYouSettlesUp() {
        var ledger = ledger()
        let hers = UUID()
        ledger.accountOwners = [hers: .partner]
        let groceries = tx("-100.00", owner: .shared)
        var paidBack = tx("-50.00", "Internal transfer")
        paidBack.accountID = hers
        paidBack.subcategory = "Between you"
        XCTAssertEqual(ledger.balance([groceries]).amount, 50)
        XCTAssertEqual(ledger.balance([groceries, paidBack]).amount, 0, "She sent me her half")
        var ordinary = paidBack
        ordinary.subcategory = "Between accounts"
        XCTAssertEqual(ledger.balance([groceries, ordinary]).amount, 50, "Her own savings move changes nothing")
    }
}
