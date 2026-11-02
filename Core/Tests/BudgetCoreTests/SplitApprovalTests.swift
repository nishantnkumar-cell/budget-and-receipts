import XCTest
@testable import BudgetCore
final class SplitApprovalTests:XCTestCase{func testDraftTotal(){let r=ReceiptRecord(imagePath:"",merchant:"Shop",purchaseDate:nil,subtotal:nil,tax:nil,total:money("3.69"),rawText:"",items:[],confidence:1);let d=SplitDraft(receipt:r,proposedSplits:[TransactionSplit(label:"Milk",category:"Groceries",amount:money("2.49")),TransactionSplit(label:"Bread",category:"Groceries",amount:money("1.20"))]);XCTAssertEqual(d.splitTotal,money("3.69"))}}
