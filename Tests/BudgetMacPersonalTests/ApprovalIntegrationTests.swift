import XCTest
@testable import BudgetMacPersonal
@MainActor final class ApprovalIntegrationTests: XCTestCase {
    func testReviewRequired() {
        let r=ReceiptRecord(imagePath:"",merchant:"Shop",purchaseDate:nil,subtotal:nil,tax:nil,total:3.69,rawText:"",items:[],confidence:1)
        let d=SplitDraft(receipt:r,proposedSplits:[TransactionSplit(label:"Milk",category:"Groceries",amount:3.69)])
        XCTAssertEqual(SplitApprovalPolicy().validate(d, bankAmount:-3.69, reviewed:false).failureValue,.notReviewed)
    }
    func testApprovalCommitsAndClearsDraft() {
        let tx=Transaction(date:Date(),merchant:"Shop",amount:-3.69,fingerprint:"tx")
        let r=ReceiptRecord(imagePath:"",merchant:"Shop",purchaseDate:nil,subtotal:nil,tax:nil,total:3.69,rawText:"",items:[],confidence:1)
        let d=SplitDraft(receipt:r,proposedSplits:[TransactionSplit(label:"Milk",category:"Groceries",amount:3.69)])
        let store=BudgetStore(); store.transactions=[tx]; store.saveDraft(d,for:tx); store.approve(d,for:tx)
        XCTAssertEqual(store.transactions[0].splits.count,1); XCTAssertNil(store.transactions[0].pendingSplitDraft); XCTAssertEqual(store.changes.count,1)
    }
}
private extension Result where Failure == SplitApprovalFailure { var failureValue: Failure? { if case let .failure(v)=self{return v};return nil } }
