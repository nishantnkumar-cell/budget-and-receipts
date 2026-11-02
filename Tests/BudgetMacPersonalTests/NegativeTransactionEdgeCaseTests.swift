import XCTest
@testable import BudgetMacPersonal

final class NegativeTransactionEdgeCaseTests: XCTestCase {
    private func draft(_ amounts: [Decimal]) -> SplitDraft {
        let receipt = ReceiptRecord(imagePath: "", merchant: "Shop", purchaseDate: nil, subtotal: nil, tax: nil, total: amounts.reduce(0,+), rawText: "", items: [], confidence: 1)
        return SplitDraft(receipt: receipt, proposedSplits: amounts.enumerated().map { TransactionSplit(label: "Purchase item \($0.offset + 1)", category: "Shopping", amount: $0.element) })
    }

    func testNegativePurchaseUsesAbsoluteBankAmount() {
        let result = SplitApprovalPolicy().validate(draft([78.88]), bankAmount: -78.88, reviewed: true)
        guard case .success = result else { return XCTFail("Negative debit should compare by magnitude") }
    }

    func testLargeNegativePurchaseCanBeSplit() {
        let result = SplitApprovalPolicy().validate(draft([500.00, 150.00]), bankAmount: -650.00, reviewed: true)
        guard case .success = result else { return XCTFail("Large negative purchase should split normally") }
    }

    func testZeroBankTransactionRejectsPositiveAllocation() {
        let result = SplitApprovalPolicy().validate(draft([0.01]), bankAmount: 0, reviewed: true)
        XCTAssertEqual(result.failureValue, .unbalanced)
    }

    func testNegativeLineItemIsRejected() {
        let result = SplitApprovalPolicy().validate(draft([10.00, -1.00]), bankAmount: -9.00, reviewed: true)
        XCTAssertEqual(result.failureValue, .invalidItem(1))
    }
}

private extension Result where Failure == SplitApprovalFailure {
    var failureValue: Failure? { if case let .failure(value) = self { return value }; return nil }
}
