import XCTest
@testable import BudgetCore
final class BalanceValidationTests: XCTestCase {
    func testBalancedDraftPasses() {
        let r=ReceiptRecord(imagePath:"",merchant:"Shop",purchaseDate:nil,subtotal:nil,tax:nil,total:money("3.69"),rawText:"",items:[],confidence:1)
        let d=SplitDraft(receipt:r,proposedSplits:[TransactionSplit(label:"Milk",category:"Groceries",amount:money("2.49")),TransactionSplit(label:"Bread",category:"Groceries",amount:money("1.20"))])
        guard case .success = SplitApprovalPolicy().validate(d, bankAmount:-money("3.69"), reviewed:true) else { return XCTFail() }
    }
    func testUnbalancedDraftFails() {
        let r=ReceiptRecord(imagePath:"",merchant:"Shop",purchaseDate:nil,subtotal:nil,tax:nil,total:3,rawText:"",items:[],confidence:1)
        let d=SplitDraft(receipt:r,proposedSplits:[TransactionSplit(label:"Milk",category:"Groceries",amount:3)])
        XCTAssertEqual(SplitApprovalPolicy().validate(d, bankAmount:-money("3.69"), reviewed:true).failureValue,.unbalanced)
    }
}
private extension Result where Failure == SplitApprovalFailure { var failureValue: Failure? { if case let .failure(v)=self{return v};return nil } }
