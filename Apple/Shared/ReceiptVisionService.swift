import BudgetCore
import Foundation
import ImageIO
import PDFKit
import Vision
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Reads receipt text on the device with Apple Vision, and Apple Intelligence for hard
/// receipts when the device has it. Nothing leaves the device.
actor ReceiptVisionService {
    #if os(iOS)
    func recognise(image: UIImage) async throws -> ReceiptDraftEditor {
        guard let cgImage = image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        return try await recognise(cgImage: cgImage)
    }
    #endif

    #if os(macOS)
    func recognise(url: URL) async throws -> ReceiptDraftEditor {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await recognise(cgImage: cgImage)
    }
    #endif

    /// Reads a receipt from image file data (JPEG, PNG, HEIC). Works on iPhone and Mac.
    func recognise(data: Data) async throws -> ReceiptDraftEditor {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try await recognise(cgImage: cgImage)
    }

    /// Reads a PDF e-receipt. Most have real text, which is exact; a scanned PDF is read
    /// with Vision from its first page. Also returns a JPEG of the first page to keep.
    func recognise(pdf data: Data) async throws -> (editor: ReceiptDraftEditor, preview: Data?) {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { throw CocoaError(.fileReadCorruptFile) }
        let preview = Self.jpeg(page.thumbnail(of: CGSize(width: 1200, height: 1700), for: .mediaBox))
        let lines = (document.string ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.count >= 2 {
            return (await improveIfNeeded(ReceiptParser.parse(lines)), preview)
        }
        guard let preview else { throw CocoaError(.fileReadUnknown) }
        return (try await recognise(data: preview), preview)
    }

    #if os(iOS)
    private static func jpeg(_ image: UIImage) -> Data? { image.jpegData(compressionQuality: 0.8) }
    #else
    private static func jpeg(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
    #endif

    private func improveIfNeeded(_ parsed: ReceiptDraftEditor) async -> ReceiptDraftEditor {
        // Only ask the on-device model when the rules could not make the items add up.
        guard AppSettings.smartReceipts, ReceiptAIMerge.needsHelp(parsed) else { return parsed }
        return await ReceiptAIService.improve(parsed)
    }

    private func recognise(cgImage: CGImage) async throws -> ReceiptDraftEditor {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-GB", "en-US"]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return await improveIfNeeded(ReceiptParser.parse(lines))
    }
}
