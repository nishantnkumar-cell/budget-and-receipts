import BudgetCore
import Foundation
import ImageIO
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

    private func recognise(cgImage: CGImage) async throws -> ReceiptDraftEditor {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-GB", "en-US"]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw CocoaError(.fileReadUnknown) }
        let parsed = ReceiptParser.parse(lines)
        // Only ask the on-device model when the rules could not make the items add up.
        guard AppSettings.smartReceipts, ReceiptAIMerge.needsHelp(parsed) else { return parsed }
        return await ReceiptAIService.improve(parsed)
    }
}
