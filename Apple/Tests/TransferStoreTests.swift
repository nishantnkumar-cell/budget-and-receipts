import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class TransferStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTransfersLeaveSpendingButYourChoiceStays() {
        let store = BudgetStore(folder: folder)
        let natwest = store.addAccount(name: "NatWest")
        let firstDirect = store.addAccount(name: "first direct")
        var out = BankTransaction(date: Date(), merchant: "OnLine Transaction FP 06", amount: -800, category: "Savings & investments", fingerprint: "out")
        out.accountID = natwest.id
        var into = BankTransaction(date: Date(), merchant: "CR KUMAR N", amount: 800, category: "Income", fingerprint: "in")
        into.accountID = firstDirect.id
        var amex = BankTransaction(date: Date(), merchant: "DD AMERICAN EXPRESS", amount: -300, category: "Shopping", fingerprint: "amex")
        amex.categoryChosen = true
        store.transactions = [out, into, amex, BankTransaction(date: Date(), merchant: "TESCO", amount: -40, category: "Groceries", fingerprint: "tesco")]
        XCTAssertEqual(store.markTransfers(), 2)
        XCTAssertEqual(store.monthReport.spending, 340, "Tesco, plus the card bill you chose to keep as Shopping")
        XCTAssertEqual(store.monthReport.income, 0)
        XCTAssertEqual(store.markTransfers(), 0, "Nothing left to change")
    }
}
