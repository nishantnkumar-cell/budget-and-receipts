import XCTest
@testable import BudgetCore

final class CategoriserTests: XCTestCase {
    func testBankCodesAndCommonUKNamesAreCategorised() {
        let categoriser = Categoriser(history: [])
        func category(_ merchant: String, _ amount: Decimal) -> String? {
            categoriser.suggest(for: BankTransaction(date: Date(), merchant: merchant, amount: amount, fingerprint: ""))?.category
        }
        XCTAssertEqual(category("DIRECT DEBIT PAYMENT - THANK YOU", 1180.13), "Card payment")
        XCTAssertEqual(category("CR ACME TECHNOLOGIES U", 2400), "Income")
        XCTAssertEqual(category("CR VINTED REFUND", 11.14), "Shopping", "A refund takes away from what was bought there")
        XCTAssertEqual(category("DD ID MOBILE LIMITED", -12), "Bills & utilities")
        XCTAssertEqual(category("SO NS&I 1234567890", -50), "Savings & investments")
        XCTAssertEqual(category("TKMAXX_UK London", -30), "Shopping")
        XCTAssertEqual(category("TWICKENHAM PLANT CENTR WHITTON ENG", -9.5), "Shopping")
    }

    private func tx(_ merchant: String, _ amount: String = "-10.00", category: String = "Uncategorised", splits: [TransactionSplit] = []) -> BankTransaction {
        BankTransaction(date: Date(), merchant: merchant, amount: money(amount), category: category, fingerprint: UUID().uuidString, splits: splits)
    }

    func testMerchantKeyDropsStatementNoise() {
        XCTAssertEqual(Categoriser.merchantKey("CARD PAYMENT TO TESCO STORES 3297 LONDON"), "TESCO STORES")
        XCTAssertEqual(Categoriser.merchantKey("Sainsbury's S/mkts"), "SAINSBURYS S")
    }

    func testBuiltInListKnowsCommonShops() {
        let categoriser = Categoriser()
        XCTAssertEqual(categoriser.suggest(for: tx("TESCO STORES 3297"))?.category, "Groceries")
        XCTAssertEqual(categoriser.suggest(for: tx("NETFLIX.COM"))?.category, "Subscriptions")
        XCTAssertEqual(categoriser.suggest(for: tx("TFL TRAVEL CH"))?.category, "Transport")
        XCTAssertEqual(categoriser.suggest(for: tx("Sainsbury's"))?.source, .keyword)
        XCTAssertNil(categoriser.suggest(for: tx("JOE BLOGGS LTD")))
    }

    func testShortKeywordsOnlyMatchWholeWords() {
        // "BP" must not match inside "BPXYZ" or "ABP".
        XCTAssertNil(Categoriser().suggest(for: tx("ABP PROPERTIES")))
        XCTAssertEqual(Categoriser().suggest(for: tx("BP CONNECT 123"))?.category, "Transport")
    }

    func testWhatYouChoseBeforeWins() {
        let history = [tx("TESCO STORES 1111", category: "Shopping"), tx("TESCO STORES 2222", category: "Shopping"), tx("TESCO STORES 3333", category: "Groceries")]
        let suggestion = Categoriser(history: history).suggest(for: tx("TESCO STORES 9999"))
        XCTAssertEqual(suggestion?.category, "Shopping")
        XCTAssertEqual(suggestion?.source, .learned)
        XCTAssertEqual(suggestion?.confidence ?? 0, 2.0 / 3.0, accuracy: 0.001)
    }

    func testUncategorisedHistoryTeachesNothing() {
        XCTAssertEqual(Categoriser(history: [tx("TESCO STORES", category: "Uncategorised")]).suggest(for: tx("TESCO STORES"))?.source, .keyword)
    }

    func testCreditsBecomeIncomeOrARefundOfTheShop() {
        XCTAssertEqual(Categoriser().suggest(for: tx("ACME LTD SALARY", "2500.00"))?.category, "Income")
        XCTAssertEqual(Categoriser().suggest(for: tx("TESCO STORES", "5.00"))?.category, "Groceries", "Money back from a shop reduces that spending, not income")
        XCTAssertNil(Categoriser().suggest(for: tx("A SMITH", "5.00")), "Money from a person is left for you to decide")
    }

    func testCategoriseLeavesYourCategoriesAlone() {
        let result = Categoriser().categorise([tx("TESCO STORES"), tx("TESCO STORES", category: "Family")])
        XCTAssertEqual(result.map(\.category), ["Groceries", "Family"])
    }

    func testItemsLearnFromApprovedSplits() {
        let past = tx("BOOTS", category: "Uncategorised", splits: [TransactionSplit(label: "Meal deal 3.50", category: "Eating out", amount: money("3.50"))])
        let categoriser = Categoriser(history: [past])
        XCTAssertEqual(categoriser.suggest(forItem: "MEAL DEAL")?.category, "Eating out")
        XCTAssertEqual(categoriser.suggest(forItem: "Semi skimmed MILK 2L")?.category, "Groceries")
        XCTAssertEqual(categoriser.suggest(forItem: "Mystery thing", merchant: "WAITROSE")?.category, "Groceries")
        XCTAssertNil(categoriser.suggest(forItem: "Mystery thing"))
    }

    func testCategoriseReceiptItems() {
        var editor = ReceiptDraftEditor(merchant: "BOOTS", items: [
            ReceiptLineItem(description: "SHAMPOO", total: money("4.00"), confidence: 1),
            ReceiptLineItem(description: "WATER", total: money("1.00"), category: "Eating out", confidence: 1)
        ])
        Categoriser().categorise(&editor)
        XCTAssertEqual(editor.items.map(\.category), ["Health", "Eating out"])
    }
}

final class ReceiptParserTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private let tesco = [
        "TESCO",
        "Welcome to Tesco Kensington",
        "VAT No: GB 220 4302 31",
        "MILK SEMI SKIMMED 2L      £1.45 A",
        "BREAD WHOLEMEAL           1.10 A",
        "2 x 0.75                  1.50 A",
        "Clubcard Price           -0.30",
        "SHAMPOO                   3.99 B",
        "SUBTOTAL                  7.74",
        "VAT                       0.67",
        "TOTAL                     7.74",
        "VISA CONTACTLESS          7.74",
        "CHANGE DUE                0.00",
        "12/10/2026 14:32"
    ]

    func testReadsAWholeSupermarketReceipt() {
        let editor = ReceiptParser.parse(tesco, calendar: calendar)
        XCTAssertEqual(editor.merchant, "TESCO")
        XCTAssertEqual(editor.receiptTotal, money("7.74"))
        XCTAssertEqual(editor.subtotal, money("7.74"))
        XCTAssertEqual(editor.tax, money("0.67"))
        XCTAssertEqual(editor.items.map(\.description), ["MILK SEMI SKIMMED 2L", "BREAD WHOLEMEAL", "2 x 0.75", "SHAMPOO"])
        XCTAssertEqual(editor.items.map(\.total), [money("1.45"), money("1.10"), money("1.20"), money("3.99")])
        XCTAssertEqual(editor.splitTotal, money("7.74"), "Items after the discount add up to the total")
        XCTAssertEqual(editor.purchaseDate, calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12)))
    }

    func testAmountFormats() {
        XCTAssertEqual(ReceiptParser.amountAtEnd("Milk £1.20"), money("1.20"))
        XCTAssertEqual(ReceiptParser.amountAtEnd("TV 1,234.50"), money("1234.50"))
        XCTAssertEqual(ReceiptParser.amountAtEnd("Brot 12,50"), money("12.50"))
        XCTAssertEqual(ReceiptParser.amountAtEnd("Offer 0.50-"), money("-0.50"))
        XCTAssertEqual(ReceiptParser.amountAtEnd("Offer -0.50"), money("-0.50"))
        XCTAssertEqual(ReceiptParser.amountAtEnd("Milk 1.20 A"), money("1.20"))
        XCTAssertNil(ReceiptParser.amountAtEnd("Table 12"))
    }

    func testDateFormats() {
        func day(_ text: String) -> DateComponents? {
            ReceiptParser.date(in: text, calendar: calendar).map { calendar.dateComponents([.year, .month, .day], from: $0) }
        }
        XCTAssertEqual(day("Date: 03-11-26"), DateComponents(year: 2026, month: 11, day: 3))
        XCTAssertEqual(day("05.01.2026"), DateComponents(year: 2026, month: 1, day: 5))
        XCTAssertEqual(day("Sat 12 Oct 2026 18:05"), DateComponents(year: 2026, month: 10, day: 12))
        XCTAssertNil(day("31/02/2026"), "No 31 February")
        XCTAssertNil(day("Table 12"))
    }

    func testDiscountNeverMakesAnItemNegative() {
        let editor = ReceiptParser.parse(["SHOP", "Gum 0.50", "Promo -1.00", "TOTAL 0.00"])
        XCTAssertEqual(editor.items.first?.total, 0)
    }

    func testBirthdayCardIsAnItemNotAPayment() {
        let editor = ReceiptParser.parse(["CARD FACTORY", "BIRTHDAY CARD 2.99", "TOTAL 2.99", "CARD 2.99"])
        XCTAssertEqual(editor.items.map(\.description), ["BIRTHDAY CARD"])
        XCTAssertEqual(editor.merchant, "CARD FACTORY")
    }

    func testWithoutATotalLineItemsAreAddedUp() {
        XCTAssertEqual(ReceiptParser.parse(["CAFE", "Latte 3.20", "Cake 2.80"]).receiptTotal, money("6.00"))
    }
}

final class ReceiptMatcherTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }

    private func payment(_ merchant: String, _ amount: String, _ d: Int, splits: [TransactionSplit] = []) -> BankTransaction {
        BankTransaction(date: day(d), merchant: merchant, amount: money(amount), fingerprint: "\(merchant)|\(amount)|\(d)", splits: splits)
    }

    func testExactAmountSameDayAndShopComesFirst() {
        let editor = ReceiptDraftEditor(merchant: "TESCO", purchaseDate: day(12), receiptTotal: money("7.74"))
        let payments = [
            payment("AMAZON", "-7.74", 12),
            payment("TESCO STORES 3297", "-7.74", 13),
            payment("TESCO STORES 3297", "-25.00", 12),
            payment("SALARY", "2500.00", 12)
        ]
        let matches = ReceiptMatcher.candidates(for: editor, in: payments, calendar: calendar)
        XCTAssertEqual(matches.first?.transaction.merchant, "TESCO STORES 3297")
        XCTAssertEqual(matches.first?.amountMatches, true)
        XCTAssertEqual(matches.count, 3, "Income is never a receipt's payment")
    }

    func testAPaymentWithATipStillRanksAboveAStranger() {
        let editor = ReceiptDraftEditor(merchant: "PIZZA EXPRESS", purchaseDate: day(5), receiptTotal: money("40.00"))
        let matches = ReceiptMatcher.candidates(for: editor, in: [payment("NEXT", "-12.00", 5), payment("PIZZA EXPRESS", "-44.00", 6)], calendar: calendar)
        XCTAssertEqual(matches.first?.transaction.merchant, "PIZZA EXPRESS")
        XCTAssertEqual(matches.first?.amountMatches, false)
    }

    func testAlreadySplitPaymentsAreSkipped() {
        let split = payment("TESCO", "-5.00", 1, splits: [TransactionSplit(label: "Milk", category: "Groceries", amount: money("5.00"))])
        XCTAssertTrue(ReceiptMatcher.candidates(for: ReceiptDraftEditor(receiptTotal: money("5.00")), in: [split], calendar: calendar).isEmpty)
    }
}
