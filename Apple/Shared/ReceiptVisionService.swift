import BudgetCore
import Foundation
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
