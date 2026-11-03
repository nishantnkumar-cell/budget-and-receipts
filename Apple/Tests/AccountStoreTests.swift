import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class AccountStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let ofx = "<OFX><BANKACCTFROM><ACCTID>12345678\n</BANKACCTFROM><STMTTRN><DTPOSTED>20261003\n<TRNAMT>-4.50\n<FITID>A1\n<NAME>COSTA\n</STMTTRN></OFX>"

    func testAccountInTheFileIsAddedOnImportOnly() throws {
        let store = BudgetStore(folder: folder)
        let preview = try store.previewImport(text: ofx, fileName: "current.ofx", mapping: nil)
        XCTAssertTrue(store.accounts.isEmpty, "Nothing is added until the import is confirmed")
        store.commitImport(preview, fileName: "current.ofx")
        XCTAssertEqual(store.accounts.map(\.label), ["Account ••5678"])
        XCTAssertEqual(store.transactions.first?.accountID, store.accounts.first?.id)
        XCTAssertEqual(BudgetStore(folder: folder).accounts.count, 1, "Saved")
    }

    func testChosenAccountAndFilter() throws {
        let store = BudgetStore(folder: folder)
        let card = store.addAccount(name: "Credit card")
        let csv = "Date,Description,Amount\r\n03/11/2026,AMAZON,-15.00\r\n"
        store.commitImport(try store.previewImport(text: csv, fileName: "card.csv", mapping: nil, account: card.id), fileName: "card.csv")
        store.commitImport(try store.previewImport(text: ofx, fileName: "current.ofx", mapping: nil), fileName: "current.ofx")
        XCTAssertEqual(store.accounts.count, 2)

        store.selectedMonth = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        store.accountFilter = card.id
        XCTAssertEqual(store.spending, 15)
        store.accountFilter = store.accounts.first { $0.id != card.id }?.id
        XCTAssertEqual(store.spending, 0, "The coffee was in October")
        XCTAssertEqual(store.spendingByAccount.first?.account?.id, card.id)
    }

    /// A statement in the partner's name, as PDFKit reads it.
    private let partnersStatement = [
        "Your Current Account statement",
        "Mrs Sara Patel",
        "Account number 87654321   Sort code 12-34-56",
        "Date Description Paid out Paid in Balance",
        "01 Oct BALANCE BROUGHT FORWARD 1,200.00",
        "03 Oct CARD PAYMENT TO TESCO STORES 3297 12.40 1,187.60",
    ]

    func testStatementInThePartnersNameIsTheirs() throws {
        let store = BudgetStore(folder: folder)
        var couple = CoupleSettings(partnerName: "Sara")
        couple.ownerName = "Nishant"
        store.updateCouple(couple)
        let preview = try store.previewImport(pdfLines: partnersStatement)
        XCTAssertEqual(preview.holderOwner, .partner)
        XCTAssertEqual(preview.newTransactions.first?.owner, .partner)
        XCTAssertEqual(preview.newTransactions.first?.paidBy, .partner)
        store.commitImport(preview, fileName: "sara.pdf")
        XCTAssertEqual(store.accounts.first?.owner, .partner)
        XCTAssertEqual(store.ledger.owner(of: store.transactions[0]), .partner)
    }

    func testOwnerYouChoseStays() throws {
        let store = BudgetStore(folder: folder)
        store.updateCouple(CoupleSettings(partnerName: "Sara"))
        var account = store.addAccount(name: "Current", number: "87654321")
        account.owner = .mine
        store.updateAccount(account)
        let preview = try store.previewImport(pdfLines: partnersStatement)
        XCTAssertNil(preview.newTransactions.first?.owner)
        store.commitImport(preview, fileName: "sara.pdf")
        XCTAssertEqual(store.accounts.first?.owner, .mine)
    }

    func testAccountsImportedBeforeThePartnerWasSetAreAssignedLater() throws {
        let store = BudgetStore(folder: folder)
        store.commitImport(try store.previewImport(pdfLines: partnersStatement), fileName: "sara.pdf")
        XCTAssertNil(store.accounts.first?.owner, "With no partner set, nothing is decided")
        store.updateCouple(CoupleSettings(partnerName: "Sara"))
        XCTAssertEqual(store.accounts.first?.owner, .partner)
        XCTAssertEqual(store.transactions.first?.paidBy, .partner)
    }

    func testDeletingAnAccountKeepsItsTransactions() throws {
        let store = BudgetStore(folder: folder)
        store.commitImport(try store.previewImport(text: ofx, fileName: "current.ofx", mapping: nil), fileName: "current.ofx")
        store.accountFilter = store.accounts[0].id
        store.deleteAccount(store.accounts[0])
        XCTAssertEqual(store.transactions.count, 1)
        XCTAssertNil(store.transactions[0].accountID)
        XCTAssertNil(store.accountFilter)
    }
}
