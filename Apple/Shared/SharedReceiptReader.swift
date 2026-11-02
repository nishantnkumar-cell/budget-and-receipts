import BudgetCore
import Foundation
import PDFKit

/// Reads files shared into the app (share sheet, "Open in", or the Mac's "Open With").
/// Receipts go to the waiting list until their payment is on a statement; bank statements
/// are imported, which also matches waiting receipts.
@MainActor
enum SharedReceiptReader {
    private static let vision = ReceiptVisionService()

    /// Reads every file the share extension left. Returns how many receipts were added.
    @discardableResult
    static func readDropped(into store: BudgetStore, folder: URL? = SharedReceiptDrop.folder) async -> Int {
        var added = 0
        for url in SharedReceiptDrop.waitingFiles(in: folder) {
            if SharedReceiptDrop.isStatement(url) {
                importStatement(url, into: store)
            } else if await read(url, into: store) {
                added += 1
            }
            // Read or not, the shared copy is not needed any more.
            try? FileManager.default.removeItem(at: url)
        }
        if added > 0 {
            store.status = "Added \(added) shared receipt\(added == 1 ? "" : "s") to Waiting for payment."
            store.matchPendingReceipts()
        }
        return added
    }

    /// Opens a file handed to the app: a statement is imported, anything else is read as a receipt.
    static func open(_ url: URL, into store: BudgetStore) async {
        if SharedReceiptDrop.isStatement(url) {
            importStatement(url, into: store)
        } else if await read(url, into: store) {
            store.matchPendingReceipts()
        }
    }

    /// Imports a shared bank statement. Lines already imported are skipped, and waiting
    /// receipts are matched to the new payments.
    @discardableResult
    static func importStatement(_ url: URL, into store: BudgetStore) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return false }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        do {
            let result = try store.previewImport(text: text, fileName: url.lastPathComponent, mapping: nil)
            store.commitImport(result, fileName: url.lastPathComponent)
            return true
        } catch {
            store.status = "Couldn't import \(url.lastPathComponent) automatically. Open Import Statement to choose its columns."
            return false
        }
    }

    /// The text lines of a PDF as they appear on the page, or nil when it has no real text (a scan).
    static func pdfLines(_ data: Data) -> [String]? {
        guard let document = PDFDocument(data: data) else { return nil }
        let lines = visualLines(document)
        return lines.count >= 2 ? lines : nil
    }

    /// Rebuilds each printed row of every page: pieces of text at the same height, left to
    /// right. PDFKit's plain text can list a table column by column (all payees, then all
    /// amounts), which loses which amount belongs to which payment; rows keep them together.
    static func visualLines(_ document: PDFDocument) -> [String] {
        var lines: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index),
                  let all = page.selection(for: page.bounds(for: .mediaBox)) else { continue }
            let pieces: [(rect: CGRect, text: String)] = all.selectionsByLine().compactMap { selection in
                guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return (selection.bounds(for: page), text)
            }
            // Top of the page first (PDF y grows upwards); pieces within 40% of a line's height share a row.
            var rows: [(midY: CGFloat, height: CGFloat, pieces: [(rect: CGRect, text: String)])] = []
            for piece in pieces.sorted(by: { $0.rect.midY > $1.rect.midY }) {
                if let last = rows.indices.last, abs(rows[last].midY - piece.rect.midY) < max(2, min(rows[last].height, piece.rect.height) * 0.4) {
                    rows[last].pieces.append(piece)
                } else {
                    rows.append((piece.rect.midY, piece.rect.height, [piece]))
                }
            }
            for row in rows {
                let text = row.pieces.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
                lines.append(contentsOf: text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
        }
        // A PDF with no positioned text (or one PDFKit can't split) falls back to its plain text.
        if lines.isEmpty, let text = document.string {
            lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return lines
    }

    /// Imports a PDF bank or credit card statement.
    @discardableResult
    static func importPDFStatement(_ lines: [String], fileName: String, into store: BudgetStore) -> Bool {
        do {
            let result = try store.previewImport(pdfLines: lines)
            store.commitImport(result, fileName: fileName)
            if let difference = result.summaryDifference {
                store.status += " Check it: the payments read differ from the statement's totals by \(difference.formatted(.currency(code: AppSettings.currency)))."
            }
            return true
        } catch {
            store.status = "Couldn't read the statement in \(fileName). Try your bank's CSV or OFX download instead."
            return false
        }
    }

    /// Reads one PDF or image file into the waiting list.
    @discardableResult
    static func read(_ url: URL, into store: BudgetStore) async -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return false }
        let ext = url.pathExtension.lowercased()
        do {
            var editor: ReceiptDraftEditor
            if ext == "pdf", let lines = pdfLines(data), PDFStatementParser.looksLikeStatement(lines) {
                // A bank statement shared as a PDF, not a receipt: import it, add no receipt.
                importPDFStatement(lines, fileName: url.lastPathComponent, into: store)
                return false
            }
            if ext == "pdf" {
                let result = try await vision.recognise(pdf: data)
                editor = result.editor
                editor.imagePath = result.preview.flatMap { try? ReceiptImageStore().save($0, fileExtension: "jpg") } ?? ""
            } else {
                editor = try await vision.recognise(data: data)
                editor.imagePath = (try? ReceiptImageStore().save(data, fileExtension: ext.isEmpty ? "jpg" : ext)) ?? ""
            }
            store.categoriser.categorise(&editor)
            store.savePending(editor)
            return true
        } catch {
            store.status = "Couldn't read \(url.lastPathComponent). Try a clearer copy."
            return false
        }
    }
}
