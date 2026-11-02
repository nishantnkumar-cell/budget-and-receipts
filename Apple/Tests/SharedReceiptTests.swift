import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class SharedReceiptTests: XCTestCase {
    private var folder: URL!
    private var drop: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        drop = folder.appendingPathComponent("Drop", isDirectory: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOnlyReceiptAndStatementFilesAreAccepted() throws {
        XCTAssertTrue(try SharedReceiptDrop.add(Data([1]), fileExtension: "PDF", to: drop))
        XCTAssertTrue(try SharedReceiptDrop.add(Data([1]), fileExtension: "ofx", to: drop))
        XCTAssertFalse(try SharedReceiptDrop.add(Data([1]), fileExtension: "zip", to: drop))
        XCTAssertEqual(SharedReceiptDrop.waitingFiles(in: drop).count, 2)
        XCTAssertTrue(SharedReceiptDrop.isStatement(URL(fileURLWithPath: "/x/October.QIF")))
        XCTAssertFalse(SharedReceiptDrop.isStatement(URL(fileURLWithPath: "/x/receipt.pdf")))
    }

    func testSharedStatementIsImportedAndMatchesAWaitingReceipt() async throws {
        let store = BudgetStore(folder: folder)
        let day = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
        store.savePending(ReceiptDraftEditor(merchant: "TESCO", purchaseDate: day, receiptTotal: Decimal(string: "12.40")))
        let csv = "Date,Description,Amount\r\n11/10/2026,TESCO STORES 3297,-12.40\r\n"
        try SharedReceiptDrop.add(Data(csv.utf8), fileExtension: "csv", to: drop)

        await SharedReceiptReader.readDropped(into: store, folder: drop)

        XCTAssertEqual(store.transactions.count, 1)
        XCTAssertNotNil(store.transactions.first?.pendingSplitDraft, "The waiting receipt was matched")
        XCTAssertTrue(store.pendingReceipts.isEmpty)
        XCTAssertTrue(SharedReceiptDrop.waitingFiles(in: drop).isEmpty, "Shared copies are removed once read")
    }

    func testTextPDFReceiptGoesToTheWaitingList() async throws {
        let store = BudgetStore(folder: folder)
        let url = drop.appendingPathComponent("e-receipt.pdf")
        try Self.pdf(lines: ["ACME BOOKS", "Novel 8.99", "Notebook 3.01", "TOTAL 12.00", "Date 01/11/2026"]).write(to: url)

        await SharedReceiptReader.open(url, into: store)

        let receipt = try XCTUnwrap(store.pendingReceipts.first)
        XCTAssertEqual(receipt.editor.merchant, "ACME BOOKS")
        XCTAssertEqual(receipt.editor.receiptTotal, Decimal(string: "12.00"))
        XCTAssertEqual(receipt.editor.items.count, 2)
    }

    func testSharedPDFStatementIsImportedNotTreatedAsAReceipt() async throws {
        let store = BudgetStore(folder: folder)
        let url = drop.appendingPathComponent("statement.pdf")
        try Self.pdf(lines: [
            "Current Account statement",
            "Account number 87654321",
            "1 October 2026 to 31 October 2026",
            "01 Oct BALANCE BROUGHT FORWARD 500.00",
            "03 Oct TESCO STORES 12.40 487.60",
            "04 Oct COSTA COFFEE 3.20 484.40",
            "05 Oct ACME SALARY 1,000.00 1,484.40",
            "06 Oct BOOTS 6.00 1,478.40",
        ]).write(to: url)

        await SharedReceiptReader.open(url, into: store)

        XCTAssertTrue(store.pendingReceipts.isEmpty, "Not a receipt")
        XCTAssertEqual(store.transactions.count, 4)
        XCTAssertEqual(store.transactions.first { $0.merchant == "ACME SALARY" }?.amount, 1000)
        XCTAssertEqual(store.accounts.map(\.label), ["Account ••4321"])
    }

    func testPartnersAccountMakesItsSpendingTheirs() async throws {
        let store = BudgetStore(folder: folder)
        store.updateCouple(CoupleSettings(partnerName: "Priya"))
        var wife = store.addAccount(name: "Priya's current", number: "87654321")
        wife.owner = .partner
        store.updateAccount(wife)
        let ofx = "<OFX><ACCTID>87654321\n<STMTTRN><DTPOSTED>20261003\n<TRNAMT>-12.40\n<FITID>A1\n<NAME>TESCO\n</STMTTRN></OFX>"
        store.commitImport(try store.previewImport(text: ofx, fileName: "priya.ofx", mapping: nil), fileName: "priya.ofx")
        XCTAssertEqual(store.transactions.first?.owner, .partner)
        XCTAssertEqual(store.transactions.first?.paidBy, .partner)
        XCTAssertNil(store.coupleBalance.debtor, "She paid for her own shopping")
    }

    /// A one-page PDF with real text, like an emailed e-receipt.
    static func pdf(lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
            context.textPosition = CGPoint(x: 20, y: 360 - CGFloat(index) * 20)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
