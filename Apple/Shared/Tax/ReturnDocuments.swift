import CoreText
import CryptoKit
import Foundation
import PDFKit
import TaxCore

/// Draws text into a PDF page, measured from the bottom left as PDF pages are.
private enum PageText {
    static func attributed(_ text: String, size: CGFloat, bold: Bool = false, red: Bool = false, faint: CGFloat = 1) -> NSAttributedString {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let colour = CGColor(srgbRed: red ? 0.75 : 0, green: 0, blue: 0, alpha: faint)
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour
        ])
    }

    static func width(_ text: NSAttributedString) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
    }

    static func line(_ text: NSAttributedString, x: CGFloat, y: CGFloat, in context: CGContext) {
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
}

/// A sheet listing every box and its figure, to copy into HMRC's online service or give to
/// an accountant.
enum ReturnSheetPDF {
    private static let page = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 42

    static func render(_ pack: ReturnPack, name: String, on date: Date = Date()) -> Data {
        let data = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        var top = page.height - margin
        context.beginPDFPage(nil)

        /// Paragraphs side by side, each in its own column, kept together on one page.
        func row(_ columns: [(text: NSAttributedString, x: CGFloat, width: CGFloat)], gap: CGFloat = 4) {
            let framed = columns.map { column -> (CTFramesetter, CGSize) in
                let setter = CTFramesetterCreateWithAttributedString(column.text)
                let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: column.width, height: 10_000), nil)
                return (setter, size)
            }
            let height = ceil(framed.map(\.1.height).max() ?? 0) + 1
            if top - height < margin {
                context.endPDFPage()
                context.beginPDFPage(nil)
                top = page.height - margin
            }
            for (column, frame) in zip(columns, framed) {
                let path = CGPath(rect: CGRect(x: column.x, y: top - height, width: column.width, height: height), transform: nil)
                context.textMatrix = .identity
                CTFrameDraw(CTFramesetterCreateFrame(frame.0, CFRange(), path, nil), context)
            }
            top -= height + gap
        }
        let full = page.width - 2 * margin
        func paragraph(_ text: String, size: CGFloat = 10, bold: Bool = false, red: Bool = false, gap: CGFloat = 4) {
            row([(PageText.attributed(text, size: size, bold: bold, red: red), margin, full)], gap: gap)
        }

        paragraph("\(pack.year.description) tax return: \(name)", size: 18, bold: true, gap: 4)
        paragraph("Made on this device on \(PropertyLedger.day(date)). Figures to check, not tax advice. Whole pounds, as the forms ask.", gap: 12)
        if !pack.problems.isEmpty {
            paragraph("NOT READY TO FILE", size: 13, bold: true, red: true)
            for problem in pack.problems { paragraph("• \(problem)", red: true) }
            top -= 8
        }
        for form in pack.forms {
            top -= 6
            // Not left alone at the foot of a page.
            if top < margin + 70 { top = margin }
            paragraph(form.title, size: 13, bold: true, gap: 6)
            for entry in form.entries {
                row([(PageText.attributed(entry.box, size: 10, bold: true), margin, 118),
                     (PageText.attributed(entry.label, size: 10), margin + 124, 270),
                     (PageText.attributed(entry.value.shown, size: 10, bold: true), margin + 402, full - 402)], gap: 5)
            }
        }
        if !pack.checks.isEmpty {
            top -= 10
            paragraph("Before you send it", size: 13, bold: true, gap: 6)
            for check in pack.checks { paragraph("• \(check)") }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// Writes figures onto HMRC's own blank forms, which have no boxes that can be typed in.
enum ReturnFormFiller {
    struct Blank: Equatable {
        var kind: ReturnFormKind
        var data: Data
        /// True when it's the very file the box positions were measured on.
        var isCheckedVersion: Bool
    }

    enum Problem: LocalizedError {
        case missing([ReturnFormKind])
        case doesNotFit(String)

        var errorDescription: String? {
            switch self {
            case .missing(let kinds): "Choose the blank \(kinds.map(\.rawValue).joined(separator: ", ")) first."
            case .doesNotFit(let box): "The figure for \(box) is too long for its box."
            }
        }
    }

    /// SHA-256 of the 2025-26 files on GOV.UK in November 2026.
    private static let checked: [ReturnFormKind: String] = [
        .main: "53841ec2138b5d1ccd8e69ae402b35e6e3a04f17556bb3b0829f55b47f51b506",
        .additional: "ed5d92aac01071976b869f416b561d1b49bbc9851561dc2055b467394ff764d1",
        .employment: "7b3c5fbe89a29be7b60df954cb8211f8bbee8289e11b1c872d4847c3b67a9f21",
        .property: "83daac11232f107009c7e174d4e0bf0424c6d305951de82924fb5f59770c9592",
        .foreign: "d803b8afae43d70e372cf9df95c95acaa0a9459123ee66a605a4bc81529d42fb"
    ]
    private static let pageCounts: [ReturnFormKind: Int] = [.main: 10, .additional: 4, .employment: 2, .property: 2, .foreign: 8]

    /// Which blank 2025-26 form a file is, or nil.
    static func identify(_ data: Data) -> Blank? {
        guard let document = PDFDocument(data: data), !document.isLocked else { return nil }
        let text = (document.string ?? "").filter { !$0.isWhitespace }
        guard let kind = ReturnFormKind.allCases.first(where: {
            pageCounts[$0] == document.pageCount && text.contains("\($0.rawValue)2026")
        }) else { return nil }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Blank(kind: kind, data: data, isCheckedVersion: checked[kind] == digest)
    }

    /// One PDF holding every copy the pack needs, filled in. Pages are marked when the figures
    /// aren't ready to file.
    static func fill(_ pack: ReturnPack, blanks: [ReturnFormKind: Blank]) throws -> Data {
        let missing = Set(pack.forms.map(\.kind)).subtracting(blanks.keys)
        guard missing.isEmpty else { throw Problem.missing(missing.sorted { $0.rawValue < $1.rawValue }) }
        let data = NSMutableData()
        var first = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &first, nil) else { return Data() }
        for form in pack.forms {
            guard let blank = blanks[form.kind], let document = PDFDocument(data: blank.data) else { throw Problem.missing([form.kind]) }
            // The employment form's second page is for a second job: each job gets its own first page.
            let pages = form.kind == .employment ? 1 : document.pageCount
            for index in 0..<pages {
                guard let page = document.page(at: index) else { continue }
                var bounds = page.bounds(for: .mediaBox)
                let box = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
                context.saveGState()
                page.draw(with: .mediaBox, to: context)
                context.restoreGState()
                for entry in form.entries {
                    guard let place = ReturnLayout.placement(of: entry.id), place.page == index + 1 else { continue }
                    try draw(entry, at: place, pageHeight: bounds.height, in: context)
                }
                if !pack.problems.isEmpty {
                    context.saveGState()
                    context.translateBy(x: 80, y: 240)
                    context.rotate(by: .pi / 4)
                    PageText.line(PageText.attributed("NOT READY TO FILE", size: 54, bold: true, red: true, faint: 0.28), x: 0, y: 0, in: context)
                    context.restoreGState()
                }
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    private static func draw(_ entry: ReturnEntry, at place: ReturnPlacement, pageHeight: CGFloat, in context: CGContext) throws {
        let baseline = pageHeight - CGFloat(place.bottom) + 4.5
        // A line of words in an undivided box, made smaller until it fits.
        if case .text(let words) = entry.value, place.cells == 1 {
            var size: CGFloat = 11
            let room = CGFloat(place.right - place.left) - 6
            while size > 5, PageText.width(PageText.attributed(words, size: size)) > room { size -= 0.5 }
            PageText.line(PageText.attributed(words, size: size), x: CGFloat(place.left) + 3, y: baseline, in: context)
            return
        }
        guard let characters = ReturnLayout.characters(entry.value, cells: place.cells) else { throw Problem.doesNotFit(entry.box) }
        let cell: CGFloat = place.cells == 1 ? CGFloat(place.right - place.left) : 13.2
        let step = place.cells == 1 ? 0 : (CGFloat(place.right - place.left) - cell) / CGFloat(place.cells - 1)
        for (index, character) in characters.enumerated() where character != " " {
            let text = PageText.attributed(String(character), size: 11, bold: true)
            let centre = CGFloat(place.left) + cell / 2 + CGFloat(index) * step
            PageText.line(text, x: centre - PageText.width(text) / 2, y: baseline, in: context)
        }
    }
}
