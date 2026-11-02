import XCTest
@testable import BudgetMacPersonal
final class DraftEditingTests: XCTestCase {
    func testAddEditDelete() {
        var editor = ReceiptDraftEditor(); editor.addItem(); let id = editor.items[0].id
        editor.editItem(id, description: "Milk", amount: 2.49, category: "Groceries")
        XCTAssertEqual(editor.items[0].description, "Milk"); XCTAssertEqual(editor.items[0].total, 2.49)
        editor.deleteItem(id); XCTAssertTrue(editor.items.isEmpty)
    }
    func testSavedDraftIsNotApproved() {
        var editor = ReceiptDraftEditor(); editor.items = [ReceiptLineItem(description: "Milk", total: 2.49, category: "Groceries", confidence: 1)]
        let draft = editor.makeDraft(reviewed: false); XCTAssertNil(draft.approvedAt); XCTAssertFalse(draft.receipt.reviewed)
    }
}
