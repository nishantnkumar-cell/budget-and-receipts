import XCTest
@testable import BudgetCore

final class PendingReceiptTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }

    private func receipt(_ merchant: String, _ total: String, _ d: Int?) -> PendingReceipt {
        PendingReceipt(scannedAt: day(d ?? 20), editor: ReceiptDraftEditor(merchant: merchant, purchaseDate: d.map(day), receiptTotal: money(total)))
    }

    private func payment(_ merchant: String, _ amount: String, _ d: Int) -> BankTransaction {
        BankTransaction(date: day(d), merchant: merchant, amount: money(amount), fingerprint: "\(merchant)|\(amount)|\(d)")
    }

    private func matches(_ pending: [PendingReceipt], _ payments: [BankTransaction]) -> [String: String] {
        let byID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0.editor.merchant) })
        return Dictionary(uniqueKeysWithValues: ReceiptMatcher.autoMatch(pending, in: payments, calendar: calendar).map { (byID[$0.receipt]!, $0.transaction) })
    }

    func testPaymentPostingDaysLaterStillMatches() {
        // Bought on Friday the 9th, on the statement on Tuesday the 13th.
        let result = matches([receipt("TESCO", "23.45", 9)], [payment("TESCO STORES 3297", "-23.45", 13)])
        XCTAssertEqual(result["TESCO"], "TESCO STORES 3297|-23.45|13")
    }

    func testOutsideTheWindowWaits() {
        XCTAssertTrue(matches([receipt("TESCO", "23.45", 1)], [payment("TESCO", "-23.45", 12)]).isEmpty, "11 days later is too far to be sure")
        XCTAssertTrue(matches([receipt("TESCO", "23.45", 10)], [payment("TESCO", "-23.45", 6)]).isEmpty, "4 days before the receipt")
        XCTAssertEqual(matches([receipt("TESCO", "23.45", 10)], [payment("TESCO", "-23.45", 8)]).count, 1, "2 days before is allowed")
    }

    func testDifferentAmountNeverAutoMatches() {
        XCTAssertTrue(matches([receipt("PIZZA", "40.00", 5)], [payment("PIZZA", "-44.00", 5)]).isEmpty, "A tip needs the person to confirm")
    }

    func testTwoPaymentsOfTheSameAmountUseTheShopName() {
        let result = matches([receipt("COSTA", "3.20", 5)], [payment("PRET", "-3.20", 5), payment("COSTA COFFEE", "-3.20", 6)])
        XCTAssertEqual(result["COSTA"], "COSTA COFFEE|-3.20|6")
    }

    func testTwoEqualCandidatesFromAnywhereWait() {
        XCTAssertTrue(matches([receipt("SHOP", "3.20", 5)], [payment("PRET", "-3.20", 5), payment("COSTA", "-3.20", 6)]).isEmpty)
    }

    func testTwoReceiptsWantingOnePaymentBothWait() {
        XCTAssertTrue(matches([receipt("TESCO", "5.00", 5), receipt("TESCO EXPRESS", "5.00", 6)], [payment("TESCO", "-5.00", 6)]).isEmpty)
    }

    func testPaymentsWithAReceiptAlreadyAreSkipped() {
        var taken = payment("TESCO", "-5.00", 5)
        taken.pendingSplitDraft = SplitDraft(receipt: ReceiptRecord(imagePath: "", merchant: "TESCO", purchaseDate: nil, subtotal: nil, tax: nil, total: money("5.00"), rawText: "", items: [], confidence: 1), proposedSplits: [])
        XCTAssertTrue(matches([receipt("TESCO", "5.00", 5)], [taken]).isEmpty)
    }

    func testReceiptWithoutADateUsesTheDayItWasScanned() {
        XCTAssertEqual(matches([receipt("TESCO", "5.00", nil)], [payment("TESCO", "-5.00", 21)]).count, 1)
    }

    func testWaitingReceiptsSaveAndLoad() throws {
        let original = receipt("TESCO", "5.00", 5)
        XCTAssertEqual(try JSONDecoder().decode(PendingReceipt.self, from: JSONEncoder().encode(original)), original)
    }
}
