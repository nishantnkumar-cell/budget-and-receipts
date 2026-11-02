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
        XCTAssertEqual(store.sharedDocuments.first?.summary, "Imported as a statement: 1 payment")
        XCTAssertNotNil(store.shareSummary, "The person is told what happened")
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

    func testTableColumnsAreReadRowByRow() throws {
        // A bank-style table: each column drawn separately, as statement PDFs often are.
        var pieces: [(CGFloat, CGFloat, String)] = [
            (20, 380, "Your Premier Statement"),
            (20, 360, "Payments In £25.00"),
            (20, 345, "Payments Out £64.30"),
            (20, 300, "30 Sep 26"), (90, 300, "BALANCE BROUGHT FORWARD"), (330, 300, "1,000.00"),
        ]
        let rows: [(String, String, String, String?)] = [
            // HSBC puts the amount on the last line of a two-line entry.
            ("01 Oct 26", "))) WAITROSE STORES", "", nil),
            ("", "HAMPTON 612", "12.40", "987.60"),
            ("02 Oct 26", "DD ID MOBILE LIMITED", "31.49", "956.11"),
            ("03 Oct 26", "CR REFUND SHOP", "25.00", "981.11"),
            ("04 Oct 26", "))) TESCO STORES", "20.41", "960.70"),
            ("", "BALANCE CARRIED FORWARD", "", "960.70"),
        ]
        var y: CGFloat = 285
        for row in rows {
            if !row.0.isEmpty { pieces.append((20, y, row.0)) }
            pieces.append((90, y, row.1))
            if !row.2.isEmpty { pieces.append((row.1.hasPrefix("CR") ? 260 : 210, y, row.2)) }
            if let balance = row.3 { pieces.append((330, y, balance)) }
            y -= 15
        }
        let data = Self.pdf(pieces: pieces)
        let lines = try XCTUnwrap(SharedReceiptReader.pdfLines(data))
        XCTAssertTrue(lines.contains("02 Oct 26 DD ID MOBILE LIMITED 31.49 956.11"), "\(lines)")
        let parsed = try PDFStatementParser.parse(lines, fallbackYear: 2026)
        XCTAssertEqual(parsed.map(\.amount), [-12.40, -31.49, 25.00, -20.41].map { Decimal(string: "\($0)")! })
        XCTAssertNil(PDFStatementParser.summaryDifference(lines, rows: parsed))
    }

    func testUnreadableFileIsListedWithTheReason() async throws {
        let store = BudgetStore(folder: folder)
        let url = drop.appendingPathComponent("blank.pdf")
        try Self.pdf(lines: []).write(to: url)
        await SharedReceiptReader.open(url, into: store)
        guard case .failed(let reason)? = store.sharedDocuments.first?.outcome else { return XCTFail("Should be listed as failed") }
        XCTAssertTrue(reason.contains("no text"))
        XCTAssertTrue(store.pendingReceipts.isEmpty)
    }

    func testStatementTakenForAReceiptCanBeImportedInstead() throws {
        let store = BudgetStore(folder: folder)
        // As an earlier version left it: a statement's text saved as a waiting receipt.
        let text = ["Your Account statement", "Date Payment type and details Paid out Paid in Balance",
                    "01 Oct 26 BALANCE BROUGHT FORWARD 100.00", "03 Oct 26 TESCO 10.00 90.00",
                    "04 Oct 26 COSTA 3.00 87.00", "05 Oct 26 BOOTS 2.00 85.00", "06 Oct 26 PRET 5.00 80.00"].joined(separator: "\n")
        store.savePending(ReceiptDraftEditor(merchant: "Your Account statement", rawText: text))
        let outcome = SharedReceiptReader.importAsStatement(store.pendingReceipts[0], store: store)
        guard case .statement(let imported, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(imported, 4)
        XCTAssertTrue(store.pendingReceipts.isEmpty)
        XCTAssertEqual(store.transactions.count, 4)
        XCTAssertEqual(store.sharedDocuments.count, 1)
    }

    static func pdf(pieces: [(CGFloat, CGFloat, String)]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 420, height: 400)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        for (x, y, text) in pieces {
            let line = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 9, nil)])
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
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
