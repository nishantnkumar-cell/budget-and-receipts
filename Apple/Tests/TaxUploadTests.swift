import BudgetCore
import PDFKit
import TaxCore
import XCTest
@testable import BudgetReceipts

/// Reads made-up documents drawn as real PDFs, the way the app reads chosen files.
@MainActor
final class TaxUploadTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A one-page PDF with each piece of text at its place.
    private func pdf(_ pieces: [(x: CGFloat, y: CGFloat, text: String)]) -> Data {
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &page, nil)!
        context.beginPDFPage(nil)
        for piece in pieces {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: piece.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 10, nil)]))
            context.textPosition = CGPoint(x: piece.x, y: 800 - piece.y)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func lines(_ texts: [String]) -> Data {
        pdf(texts.enumerated().map { (40, CGFloat($0.offset) * 18, $0.element) })
    }

    func testReadsARemittanceAdvicePDF() throws {
        let data = lines(["REMITTANCE ADVICE", "Statement reference : SL_0001",
                          "Rent receipt 20.06.2025 - 19.07.2025 £1,200.00 £1,200.00",
                          "Management fee INV7 £120.00 £24.00 £144.00",
                          "Total Expenditure £144.00", "Paid £1,056.00 via Bank Transfer on 23.06.2025"])
        let statement = try LettingStatementReader.read(texts: UploadFile.pdfTexts(data))
        XCTAssertTrue(statement.isChecked, "\(statement.warnings)")
        XCTAssertEqual(statement.fees, 144)
        XCTAssertEqual(statement.paidToYou, 1_056)
    }

    func testReadsATableWithLabelsAndAmountsInSeparateColumns() throws {
        // Drawn column by column, as some files are, so only the rows keep them together.
        let labels = ["Total Taxable Pay", "Total Deductions", "PAYE Net Pay"]
        let values = ["£2,200.00", "£400.00", "£1,800.00"]
        var pieces: [(x: CGFloat, y: CGFloat, text: String)] = [(40, 0, "Pay Date/ Tax Period 06/06/2025 / 9"), (40, 20, "Income Tax £300.00")]
        pieces += labels.enumerated().map { (40, 40 + CGFloat($0.offset) * 18, $0.element) }
        pieces += values.enumerated().map { (220, 40 + CGFloat($0.offset) * 18, $0.element) }
        pieces += [(40, 120, "To Date Figures"), (40, 140, "Taxable Pay"), (40, 158, "Income Tax")]
        pieces += [(220, 140, "£19,800.00"), (220, 158, "£2,700.00")]
        let slip = try PayslipReader.read(texts: UploadFile.pdfTexts(pdf(pieces)))
        XCTAssertEqual(slip.taxablePayToDate, 19_800)
        XCTAssertEqual(slip.taxToDate, 2_700)
        XCTAssertTrue(slip.isChecked, "\(slip.warnings)")
    }

    func testAPayslipSharedIntoTheAppIsNeverImportedAsPayments() async throws {
        let url = folder.appendingPathComponent("payslip.pdf")
        try lines(["Pay Date/ Tax Period 06/06/2025 / 9", "Total Taxable Pay £2,200.00", "Total Deductions £400.00",
                   "PAYE Net Pay £1,800.00"]).write(to: url)
        let store = BudgetStore(folder: folder)
        let document = await SharedReceiptReader.process(url, into: store)
        guard case .failed(let reason) = document.outcome else { return XCTFail("\(document.outcome)") }
        XCTAssertTrue(reason.contains("payslip"))
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertTrue(store.pendingReceipts.isEmpty)
    }

    func testAnImportedPayslipIsSaved() {
        let tax = TaxStore(folder: folder)
        tax.change { book in
            book.record(payslipDated: TaxYear.day(2025, 6, 6), taxablePay: 100, taxDeducted: 10, person: .me, employer: "Umbrella")
        }
        XCTAssertEqual(TaxStore(folder: folder).book.pay.first?.payslipDate, tax.book.pay.first?.payslipDate)
        XCTAssertEqual(tax.syncRecords().map(\.isPrivate), [true])
    }
}
