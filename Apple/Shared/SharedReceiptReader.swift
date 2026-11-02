import BudgetCore
import Foundation
import PDFKit

/// Reads files shared into the app (share sheet, "Open in", or the Mac's "Open With").
/// Receipts go to the waiting list until their payment is on a statement; bank statements
/// are imported, which also matches waiting receipts.
@MainActor
enum SharedReceiptReader {
    private static let vision = ReceiptVisionService()

    /// Reads every file the share extension left, then says once what happened to them.
    static func readDropped(into store: BudgetStore, folder: URL? = SharedReceiptDrop.folder) async {
        var documents: [SharedDocument] = []
        for url in SharedReceiptDrop.waitingFiles(in: folder) {
            documents.append(await process(url, into: store))
            // The shared copy is not needed any more; the app keeps its own.
            try? FileManager.default.removeItem(at: url)
        }
        finish(documents, store: store)
    }

    /// Opens a file handed to the app ("Open in", or Open With on the Mac).
    static func open(_ url: URL, into store: BudgetStore) async {
        let document = await process(url, into: store)
        finish([document], store: store)
    }

    private static func finish(_ documents: [SharedDocument], store: BudgetStore) {
        guard !documents.isEmpty else { return }
        store.matchPendingReceipts()
        let lines = documents.map { "\($0.fileName): \($0.summary)." }
        store.shareSummary = lines.joined(separator: "\n")
        store.status = documents.count == 1 ? lines[0] : "Read \(documents.count) shared files. See Inbox › Shared files."
    }

    /// Reads one shared file: a CSV, OFX, QFX or QIF statement is imported; a PDF that looks
    /// like a statement is imported; anything else is read as a receipt. Every outcome,
    /// including a failure and why, is recorded in Shared files.
    @discardableResult
    static func process(_ url: URL, into store: BudgetStore) async -> SharedDocument {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            return recorded(SharedDocument(fileName: name, outcome: .failed(reason: "the file couldn't be opened")), store)
        }
        let stored = "\(UUID().uuidString).\(url.pathExtension.lowercased())"
        try? data.write(to: store.sharedFilesFolder.appendingPathComponent(stored), options: .atomic)
        var document = SharedDocument(fileName: name, outcome: .failed(reason: "unknown"), storedFile: stored)
        let ext = url.pathExtension.lowercased()

        if SharedReceiptDrop.isStatement(url) {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            do {
                document.outcome = importResult(try store.previewImport(text: text, fileName: name, mapping: nil), fileName: name, store: store)
            } catch {
                document.outcome = .failed(reason: "its columns couldn't be worked out. Use Import Statement to choose them")
            }
            return recorded(document, store)
        }
        if ext == "pdf", let lines = pdfLines(data), PDFStatementParser.looksLikeStatement(lines) {
            document.outcome = importPDF(lines, fileName: name, store: store)
            return recorded(document, store)
        }
        do {
            var editor: ReceiptDraftEditor
            if ext == "pdf" {
                let result = try await vision.recognise(pdf: data)
                editor = result.editor
                editor.imagePath = result.preview.flatMap { try? ReceiptImageStore().save($0, fileExtension: "jpg") } ?? ""
            } else {
                editor = try await vision.recognise(data: data)
                editor.imagePath = (try? ReceiptImageStore().save(data, fileExtension: ext.isEmpty ? "jpg" : ext)) ?? ""
            }
            store.categoriser.categorise(&editor)
            let pending = PendingReceipt(editor: editor)
            store.pendingReceipts.append(pending)
            document.outcome = .receipt(pendingID: pending.id)
        } catch {
            document.outcome = .failed(reason: ext == "pdf" ? "no text could be read from this PDF" : "no text could be read from this image. Try a sharper photo")
        }
        return recorded(document, store)
    }

    /// Reads a waiting receipt again as a statement: for a statement the app took for a receipt.
    @discardableResult
    static func importAsStatement(_ receipt: PendingReceipt, store: BudgetStore) -> SharedDocument.Outcome {
        var document = store.sharedDocument(forReceipt: receipt.id)
        let original = document?.storedFile.flatMap { try? Data(contentsOf: store.sharedFilesFolder.appendingPathComponent($0)) }
        let lines = original.flatMap(pdfLines)
            ?? receipt.editor.rawText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let outcome = importPDF(lines, fileName: document?.fileName ?? receipt.editor.merchant, store: store)
        if case .statement = outcome {
            store.pendingReceipts.removeAll { $0.id == receipt.id }
            if document == nil { document = SharedDocument(fileName: receipt.editor.merchant.isEmpty ? "Statement" : receipt.editor.merchant, outcome: outcome) }
        }
        if var document {
            document.outcome = outcome
            store.sharedDocuments.contains { $0.id == document.id } ? store.update(document) : store.record(document)
        }
        store.shareSummary = document.map { "\($0.fileName): \($0.summary)." }
        return outcome
    }

    private static func importPDF(_ lines: [String], fileName: String, store: BudgetStore) -> SharedDocument.Outcome {
        do {
            return importResult(try store.previewImport(pdfLines: lines), fileName: fileName, store: store)
        } catch {
            return .failed(reason: "no payments could be found in this statement. Try your bank's CSV or OFX download")
        }
    }

    private static func importResult(_ result: StatementImportResult, fileName: String, store: BudgetStore) -> SharedDocument.Outcome {
        store.commitImport(result, fileName: fileName)
        return .statement(imported: result.newTransactions.count, alreadyThere: result.duplicates.count, totalsDifference: result.summaryDifference)
    }

    private static func recorded(_ document: SharedDocument, _ store: BudgetStore) -> SharedDocument {
        store.record(document)
        return document
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
}
