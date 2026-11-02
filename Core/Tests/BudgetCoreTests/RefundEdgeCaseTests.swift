import XCTest
@testable import BudgetCore

final class RefundEdgeCaseTests: XCTestCase {
    private func draft(_ amounts: [Decimal]) -> SplitDraft {
        let receipt = ReceiptRecord(imagePath: "", merchant: "Refund merchant", purchaseDate: nil, subtotal: nil, tax: nil, total: amounts.reduce(0,+), rawText: "", items: [], confidence: 1)
        return SplitDraft(receipt: receipt, proposedSplits: amounts.enumerated().map { TransactionSplit(label: "Refund item \($0.offset + 1)", category: "Shopping", amount: $0.element) })
    }

    func testPositiveBankCreditCanBeAllocatedAsRefund() {
        let result = SplitApprovalPolicy().validate(draft([money("32.37")]), bankAmount: money("32.37"), reviewed: true)
        guard case .success = result else { return XCTFail("A positive refund transaction should approve") }
    }

    func testPartialRefundCanBeSplitAcrossOriginalCategories() {
        let result = SplitApprovalPolicy().validate(draft([money("20.00"), money("12.37")]), bankAmount: money("32.37"), reviewed: true)
        guard case .success = result else { return XCTFail("A partial refund split should approve when balanced") }
    }

    func testRefundOverAllocationFails() {
        let result = SplitApprovalPolicy().validate(draft([money("20.00"), money("12.38")]), bankAmount: money("32.37"), reviewed: true)
        XCTAssertEqual(result.failureValue, .unbalanced)
    }

    func testNegativeSplitLineIsRejectedEvenForRefund() {
        let result = SplitApprovalPolicy().validate(draft([money("40.00"), -money("7.63")]), bankAmount: money("32.37"), reviewed: true)
        XCTAssertEqual(result.failureValue, .invalidItem(1))
    }
}

private extension Result where Failure == SplitApprovalFailure {
    var failureValue: Failure? { if case let .failure(value) = self { return value }; return nil }
}
