import BudgetCore
import Foundation
import ImageIO
import Vision
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Reads receipt text on the device with Apple Vision. Nothing leaves the device.
actor ReceiptVisionService {
    #if os(iOS)
    func recognise(image: UIImage) throws -> ReceiptDraftEditor {
        guard let cgImage = image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        return try recognise(cgImage: cgImage)
    }
    #endif

    #if os(macOS)
    func recognise(url: URL) throws -> ReceiptDraftEditor {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try recognise(cgImage: cgImage)
    }
    #endif

    /// Reads a receipt from image file data (JPEG, PNG, HEIC). Works on iPhone and Mac.
    func recognise(data: Data) throws -> ReceiptDraftEditor {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try recognise(cgImage: cgImage)
    }

    private func recognise(cgImage: CGImage) throws -> ReceiptDraftEditor {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-GB", "en-US"]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return ReceiptParser.parse(lines)
    }
}
