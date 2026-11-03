import BudgetCore
import XCTest
@testable import BudgetReceipts

/// The search shared by Activity, the Mac Overview and ⌘K.
final class TransactionSearchTests: XCTestCase {
    private func payment(_ merchant: String, _ amount: String, category: String = "Groceries", tags: [String]? = nil) -> BankTransaction {
        var transaction = BankTransaction(date: Date(), merchant: merchant, amount: Decimal(string: amount)!, category: category, fingerprint: UUID().uuidString)
        transaction.tags = tags
        return transaction
    }

    func testFindsShopCategoryAndTag() {
        let tesco = payment("TESCO STORES", "-12.50", tags: ["holiday"])
        XCTAssertTrue(tesco.matches("tesco"))
        XCTAssertTrue(tesco.matches("groc"))
        XCTAssertTrue(tesco.matches("Holiday"))
        XCTAssertFalse(tesco.matches("amazon"))
        XCTAssertTrue(tesco.matches("  "), "An empty search shows everything")
    }

    func testFindsAmountWithOrWithoutCurrencySign() {
        let tesco = payment("TESCO STORES", "-12.50")
        XCTAssertTrue(tesco.matches("12.50"))
        XCTAssertTrue(tesco.matches("12.5"))
        XCTAssertTrue(tesco.matches("£12.50"))
        XCTAssertTrue(tesco.matches("$12.50"))
        XCTAssertFalse(tesco.matches("12.49"))
    }

    func testWordsWithNumbersAreNotAmounts() {
        XCTAssertFalse(payment("SHOP", "-2").matches("Tesco 2"))
    }
}
