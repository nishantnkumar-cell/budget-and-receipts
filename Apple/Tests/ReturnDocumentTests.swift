import BudgetCore
import PDFKit
import TaxCore
import XCTest
@testable import BudgetReceipts

/// The sheet and the filled forms, with made-up figures and stand-in blank forms.
@MainActor
final class ReturnDocumentTests: XCTestCase {
    private let year = TaxYear(startYear: 2025)

    /// A ledger with no property and nothing to sort out.
    private func ledger(_ book: PropertyBook) -> PropertyLedger {
        var ledger = PropertyLedger.build(transactions: [], book: book, year: year)
        ledger.issues = []
        return ledger
    }

    private var pack: ReturnPack {
        let job = TaxPay(id: "job", person: .me, taxYear: "2025-26", employer: "Imaginary Employer", taxablePay: 54_321,
                         taxDeducted: 9_876)
        let book = PropertyBook(pay: [job])
        return ReturnPack.make(.me, year: year, ledger: ledger(book), book: book, today: TaxYear.day(2026, 11, 26))
    }

    /// A stand-in for a blank form: the right number of pages, each saying which form it is.
    private func blank(_ kind: ReturnFormKind, pages: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: "\(kind.rawValue) 2026 page \(page)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 10, nil)])
            context.textPosition = CGPoint(x: 40, y: 30)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func text(_ data: Data) -> String { PDFDocument(data: data)?.string ?? "" }

    func testTheSheetListsEveryBoxAndWhatToCheck() {
        let sheet = text(ReturnSheetPDF.render(pack, name: "Sample Person"))
        for expected in ["2025-26 tax return: Sample Person", "SA102 Employment: Imaginary Employer", "£54,321", "£9,876",
                         "TR 2, question 1", "31 October 2026", "Before you send it"] {
            XCTAssertTrue(sheet.contains(expected), expected)
        }
        XCTAssertFalse(sheet.contains("NOT READY"))
    }

    func testALongReturnRunsOntoMorePagesWithNothingLost() {
        let jobs = (1...40).map {
            TaxPay(id: "\($0)", person: .me, taxYear: "2025-26", employer: "Employer number \($0)", taxablePay: Decimal($0), taxDeducted: 0)
        }
        let book = PropertyBook(pay: jobs)
        let long = ReturnPack.make(.me, year: year, ledger: ledger(book), book: book)
        let data = ReturnSheetPDF.render(long, name: "Sample")
        XCTAssertGreaterThan(PDFDocument(data: data)?.pageCount ?? 0, 2)
        for job in 1...40 { XCTAssertTrue(text(data).contains("Employer number \(job)"), "\(job)") }
    }

    func testOnlyTheRightBlankFormsAreAccepted() {
        XCTAssertEqual(ReturnFormFiller.identify(blank(.property, pages: 2))?.kind, .property)
        XCTAssertEqual(ReturnFormFiller.identify(blank(.main, pages: 10))?.kind, .main)
        XCTAssertEqual(ReturnFormFiller.identify(blank(.property, pages: 2))?.isCheckedVersion, false)
        XCTAssertNil(ReturnFormFiller.identify(blank(.property, pages: 3)))
        XCTAssertNil(ReturnFormFiller.identify(Data("not a pdf".utf8)))
    }

    func testFillsTheFiguresOntoTheFormsAndKeepsTheirPages() throws {
        var blanks: [ReturnFormKind: ReturnFormFiller.Blank] = [:]
        blanks[.main] = ReturnFormFiller.identify(blank(.main, pages: 10))
        XCTAssertThrowsError(try ReturnFormFiller.fill(pack, blanks: blanks))
        blanks[.employment] = ReturnFormFiller.identify(blank(.employment, pages: 2))
        let filled = try ReturnFormFiller.fill(pack, blanks: blanks)
        let document = try XCTUnwrap(PDFDocument(data: filled))
        XCTAssertEqual(document.pageCount, 11)
        let employment = try XCTUnwrap(document.page(at: 10)?.string)
        XCTAssertTrue(employment.contains("SA102 2026 page 1"))
        XCTAssertTrue(employment.contains("Imaginary Employer"))
        XCTAssertEqual(employment.filter(\.isNumber).filter { "54321".contains($0) }.isEmpty, false)
        XCTAssertFalse(text(filled).contains("NOT READY"))
    }

    func testFormsThatArentReadyAreMarked() throws {
        var unready = pack
        unready.problems = ["Something to sort out."]
        let blanks: [ReturnFormKind: ReturnFormFiller.Blank] = [
            .main: ReturnFormFiller.identify(blank(.main, pages: 10))!,
            .employment: ReturnFormFiller.identify(blank(.employment, pages: 2))!
        ]
        XCTAssertTrue(text(try ReturnFormFiller.fill(unready, blanks: blanks)).contains("NOT READY TO FILE"))
        XCTAssertTrue(text(ReturnSheetPDF.render(unready, name: "Sample")).contains("Something to sort out."))
    }
}
