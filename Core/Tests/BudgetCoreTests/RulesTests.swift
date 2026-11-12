import XCTest
@testable import BudgetCore

final class RulesTests: XCTestCase {
    private func payment(_ merchant: String, _ amount: Decimal, category: String = "Uncategorised") -> BankTransaction {
        BankTransaction(date: Date(), merchant: merchant, amount: amount, category: category, fingerprint: merchant + "\(amount)")
    }

    func testStarterRulesCategoriseCommonUKPaymentsWithSubcategories() {
        let rules = RulesEngine.starterRules
        func result(_ merchant: String, _ amount: Decimal) -> String? {
            RulesEngine.firstMatch(rules, for: payment(merchant, amount)).map(\.resultLabel)
        }
        XCTAssertEqual(result("SAINSBURYS S/MKTS ST CLARES", -14.95), "Groceries › Supermarket")
        XCTAssertEqual(result("COSTA COFFEE 1234", -3.20), "Eating out › Coffee")
        XCTAssertEqual(result("DD ID MOBILE LIMITED", -12), "Bills & utilities › Phone")
        XCTAssertEqual(result("DIRECT DEBIT PAYMENT - THANK YOU", 1180.13), "Card payment › Credit card repayment")
        XCTAssertEqual(result("DD HSBC CARD PYMT", -1078.72), "Card payment › Credit card repayment")
        XCTAssertEqual(result("VIS NATIONAL LOTTERY WWW.NATIONAL", -5), "Entertainment › Lottery and betting")
        XCTAssertEqual(result("ATM CASH TPF AUG28 TESCO HSL HN", -150), "Cash › ATM withdrawal", "Cash beats the shop it's in")
        XCTAssertEqual(result("SUNBURY X HAIR & BEAUTY", -20), "Personal care › Hair and beauty")
        XCTAssertEqual(result("NON-STERLING TRANSACTION FEE", -1.5), "Fees & charges › Foreign transaction fees")
        XCTAssertEqual(result("IAP RINGO ECOM 03456000650", -2), "Subscriptions › Apps and games")
        XCTAssertEqual(result("TFL TRAVEL CHARGE TFL.GOV.UK/CP", -3.5), "Transport › Public transport")
        // Whole words only: "EE" isn't found inside "COFFEE".
        XCTAssertNotEqual(result("BEAN COFFEE CO", -4), "Bills & utilities › Phone")
        // A refund from a supermarket is money in, so the spending rule doesn't claim it.
        XCTAssertNil(result("TESCO STORES 3297", 12.40))
    }

    func testRulesComeBeforeLearningAndFirstMatchWins() {
        let mine = CategoryRule(name: "Tesco is family", conditions: [.init(.description, .contains, "TESCO")], category: "Family", subcategory: "Kids")
        let history = [payment("TESCO STORES 1", -10, category: "Groceries")]
        let categoriser = Categoriser(history: history, rules: [mine] + RulesEngine.starterRules)
        let suggestion = categoriser.suggest(for: payment("TESCO STORES 2", -5))
        XCTAssertEqual(suggestion?.category, "Family")
        XCTAssertEqual(suggestion?.subcategory, "Kids")
        XCTAssertEqual(suggestion?.source, .rule)
    }

    func testApplyingRulesFillsUncategorisedAndSubcategoriesOnly() {
        var transactions = [
            payment("WAITROSE 612", -20),
            payment("WAITROSE 613", -30, category: "Groceries"),
            payment("WAITROSE 614", -40, category: "Family"),
        ]
        let changed = RulesEngine.apply(RulesEngine.starterRules, to: &transactions)
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(transactions[0].category, "Groceries")
        XCTAssertEqual(transactions[0].subcategory, "Supermarket")
        XCTAssertEqual(transactions[1].subcategory, "Supermarket", "Right category already: just the sub-category")
        XCTAssertEqual(transactions[2].category, "Family", "Your own choice stays")
        XCTAssertNil(transactions[2].subcategory)
    }

    func testAmountAndAccountConditions() {
        let account = UUID()
        var big = payment("ACME LTD", -600)
        big.accountID = account
        let rule = CategoryRule(name: "Big joint costs", conditions: [.init(.amount, .greaterThan, "500"), .init(.account, .contains, "Joint")],
                                category: "Housing", subcategory: "Repairs")
        XCTAssertTrue(rule.matches(big, accountName: "HSBC Joint"))
        XCTAssertFalse(rule.matches(big, accountName: "Amex"))
        var any = rule
        any.matchAll = false
        XCTAssertTrue(any.matches(big, accountName: "Amex"))
        any.isEnabled = false
        XCTAssertFalse(any.matches(big, accountName: "HSBC Joint"))
    }

    func testStarterRulesHaveStableUniqueIdsAndValidCategories() {
        let ids = RulesEngine.starterRules.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(RulesEngine.starterRules.map(\.id), RulesEngine.starterRules.map(\.id))
        for rule in RulesEngine.starterRules {
            XCTAssertTrue(FinanceCategories.all.contains(rule.category), rule.name)
            if let sub = rule.subcategory { XCTAssertTrue(FinanceCategories.subcategories(of: rule.category).contains(sub), rule.name) }
        }
    }

    func testPaymentsBetweenAccountHoldersAreTransfers() {
        let names = PDFStatementParser.holderNames(in: ["Account Name Sortcode Account Number Sheet Number",
                                                        "MR NEIL PATEL & MRS SARA PATEL 11-22-33 11112222 488"])
        XCTAssertEqual(names, ["NEIL PATEL", "SARA PATEL"])
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["Mrs Sara Patel 44-55-66 33334444 540"]), ["SARA PATEL"])
        let rule = RulesEngine.selfTransferRule(names: names)!
        XCTAssertTrue(rule.matches(payment("OBP Neil Patel OBA3X5K8PQ21", -50)))
        XCTAssertFalse(rule.matches(payment("OBP John Smith", -50)), "Paying someone else is spending")
        XCTAssertFalse(rule.matches(payment("NEIL PATEL BOOKS", -5)), "A name alone isn't a transfer")
        XCTAssertNil(RulesEngine.selfTransferRule(names: []))
    }

    func testRuleFromAPayment() {
        let rule = RulesEngine.rule(from: payment("BIKANERVALA HOUNSLOW", -16.47), category: "Eating out", subcategory: "Sweets and bakery")
        XCTAssertEqual(rule.conditions.first?.value, "BIKANERVALA HOUNSLOW")
        XCTAssertTrue(rule.matches(payment("BIKANERVALA HOUNSLOW", -3)))
    }

    func testRulesFromPrivatePaymentsStartPrivate() throws {
        var secret = payment("GIFT SHOP", -40)
        secret.isPrivate = true
        XCTAssertEqual(RulesEngine.rule(from: secret, category: "Shopping", subcategory: nil).isPrivate, true)
        XCTAssertEqual(RulesEngine.rule(from: payment("GIFT SHOP", -40), category: "Shopping", subcategory: nil, isPrivate: true).isPrivate, true)
        XCTAssertNil(RulesEngine.rule(from: payment("GIFT SHOP", -40), category: "Shopping", subcategory: nil).isPrivate)
        // Rules and imports saved before these fields existed still load, as shared.
        let encoded = try SyncRecord.encoder().encode(CategoryRule(name: "Shop", conditions: [], category: "Shopping"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["isPrivate"] = nil
        let old = try SyncRecord.decoder().decode(CategoryRule.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.isPrivate)
        let oldImport = try SyncRecord.decoder().decode(ImportRecord.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","fileName":"a.csv","importedAt":"2026-11-01T00:00:00Z","transactionCount":3,"status":"Imported"}"#.utf8))
        XCTAssertNil(oldImport.accountID)
    }
}
