import XCTest
@testable import BudgetCore

final class ReceiptAIMergeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    /// OCR that the rules struggle with: two-column layout read as a list of names, then prices.
    private let messy = ["PRET A MANGER", "Flat White", "Croissant", "Total", "3.40", "2.60", "6.00", "Thanks!"]

    func testBalancedReadingNeedsNoHelp() {
        XCTAssertFalse(ReceiptAIMerge.needsHelp(ReceiptParser.parse(["CAFE", "Latte 3.20", "Cake 2.80", "TOTAL 6.00"])))
        XCTAssertTrue(ReceiptAIMerge.needsHelp(ReceiptParser.parse(messy)))
    }

    func testPricesOnTheirOwnLineNeedNoModel() {
        let parsed = ReceiptParser.parse(["PRET A MANGER", "Flat White", "3.40", "Croissant", "2.60", "Total", "6.00"])
        XCTAssertEqual(parsed.items.map(\.description), ["Flat White", "Croissant"])
        XCTAssertEqual(parsed.receiptTotal, money("6.00"))
        XCTAssertFalse(ReceiptAIMerge.needsHelp(parsed))
    }

    func testWithoutAnyTotalTheModelsPrintedItemsAreUsed() {
        let parsed = ReceiptParser.parse(["SHOP", "Apples", "Pears"])
        var withPrices = parsed
        withPrices.rawText = "SHOP\nApples 1.10\nPears 0.90"
        let merged = ReceiptAIMerge.merge(ReceiptAIReading(items: [.init(name: "Apples", amount: money("1.10")), .init(name: "Pears", amount: money("0.90"))]), into: withPrices)
        XCTAssertEqual(merged.items.count, 2)
        XCTAssertEqual(merged.receiptTotal, money("2.00"))
    }

    func testModelItemsReplaceAMessyReading() {
        let parsed = ReceiptParser.parse(messy, calendar: calendar)
        let ai = ReceiptAIReading(merchant: "Pret A Manger", date: "02/11/2026", total: money("6.00"), items: [
            .init(name: "Flat White", amount: money("3.40"), category: "Eating out"),
            .init(name: "Croissant", amount: money("2.60"), category: "Eating out")
        ])
        let merged = ReceiptAIMerge.merge(ai, into: parsed, calendar: calendar)
        XCTAssertEqual(merged.items.map(\.description), ["Flat White", "Croissant"])
        XCTAssertEqual(merged.items.map(\.category), ["Eating out", "Eating out"])
        XCTAssertEqual(merged.splitTotal, money("6.00"))
        XCTAssertEqual(merged.receiptTotal, money("6.00"))
        XCTAssertEqual(merged.merchant, "Pret A Manger")
        XCTAssertEqual(merged.purchaseDate, calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
    }

    func testInventedAmountsAreRejected() {
        let parsed = ReceiptParser.parse(messy, calendar: calendar)
        let ai = ReceiptAIReading(total: money("9.99"), items: [
            .init(name: "Flat White", amount: money("3.40")),
            .init(name: "Muffin", amount: money("6.59"))
        ])
        let merged = ReceiptAIMerge.merge(ai, into: parsed, calendar: calendar)
        XCTAssertEqual(merged.items, parsed.items, "One made-up price means none of the model's items are used")
        XCTAssertNotEqual(merged.receiptTotal, money("9.99"))
    }

    func testUnknownCategoriesBecomeUncategorised() {
        let parsed = ReceiptParser.parse(messy, calendar: calendar)
        let ai = ReceiptAIReading(total: money("6.00"), items: [.init(name: "Flat White", amount: money("3.40"), category: "Coffee"), .init(name: "Croissant", amount: money("2.60"))])
        XCTAssertEqual(ReceiptAIMerge.merge(ai, into: parsed, calendar: calendar).items.map(\.category), ["Uncategorised", "Uncategorised"])
    }

    func testAGoodReadingIsKeptWhenTheModelIsWorse() {
        let parsed = ReceiptParser.parse(["CAFE", "Latte 3.20", "Cake 2.80", "TOTAL 6.00"], calendar: calendar)
        let ai = ReceiptAIReading(merchant: "Something else", total: money("6.00"), items: [.init(name: "Latte", amount: money("3.20"))])
        let merged = ReceiptAIMerge.merge(ai, into: parsed, calendar: calendar)
        XCTAssertEqual(merged.items.count, 2)
        XCTAssertEqual(merged.merchant, "CAFE")
    }

    func testPrintedAmounts() {
        XCTAssertEqual(ReceiptAIMerge.printedAmounts(in: "Milk £1.20 A\nOffer 0.50-\nTV 1,234.50"), [money("1.20"), money("0.50"), money("1234.50")])
    }
}
