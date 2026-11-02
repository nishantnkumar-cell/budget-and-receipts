import XCTest
@testable import BudgetCore

final class RoundingEdgeCaseTests: XCTestCase {
    private func draft(_ amounts: [Decimal]) -> SplitDraft {
        let receipt = ReceiptRecord(imagePath: "", merchant: "Shop", purchaseDate: nil, subtotal: nil, tax: nil, total: amounts.reduce(0,+), rawText: "", items: [], confidence: 1)
        return SplitDraft(receipt: receipt, proposedSplits: amounts.enumerated().map { TransactionSplit(label: "Item \($0.offset + 1)", category: "Groceries", amount: $0.element) })
    }

    func testThreeWayPennySplitBalancesExactly() {
        let result = SplitApprovalPolicy().validate(draft([money("3.33"), money("3.33"), money("3.34")]), bankAmount: -money("10.00"), reviewed: true)
        guard case .success = result else { return XCTFail("Expected exact penny allocation to pass") }
    }

    func testHalfPennyTolerancePasses() {
        let result = SplitApprovalPolicy().validate(draft([money("9.995")]), bankAmount: -money("10.00"), reviewed: true)
        guard case .success = result else { return XCTFail("Expected half-penny tolerance to pass") }
    }

    func testMoreThanHalfPennyDifferenceFails() {
        let result = SplitApprovalPolicy().validate(draft([money("9.994")]), bankAmount: -money("10.00"), reviewed: true)
        XCTAssertEqual(result.failureValue, .unbalanced)
    }

    func testRepeatedDecimalAdditionDoesNotUseBinaryFloatingPoint() {
        let result = SplitApprovalPolicy().validate(draft([money("0.10"), money("0.20")]), bankAmount: -money("0.30"), reviewed: true)
        guard case .success = result else { return XCTFail("Decimal 0.10 + 0.20 should equal 0.30") }
    }
}

private extension Result where Failure == SplitApprovalFailure {
    var failureValue: Failure? { if case let .failure(value) = self { return value }; return nil }
}
