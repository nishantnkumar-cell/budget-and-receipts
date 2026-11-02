import BudgetCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads hard receipts with Apple's on-device language model (Apple Intelligence).
/// The model only sees the text Vision read; nothing leaves the device. Its answer is
/// checked by `ReceiptAIMerge` and stays a draft for the person to correct.
enum ReceiptAIService {
    /// Why smart reading is not available on this device, or nil when it is.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to use this."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading. Try again later."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
        #else
        return "This device doesn't support Apple Intelligence."
        #endif
    }

    /// The parsed draft, improved by the model when it is available and its answer checks out.
    static func improve(_ parsed: ReceiptDraftEditor) async -> ReceiptDraftEditor {
        #if canImport(FoundationModels)
        guard unavailableReason == nil else { return parsed }
        let session = LanguageModelSession(instructions: """
            You read shop receipts. The text comes from OCR, so item names and prices can be on separate lines.
            List every item bought with its final price. Copy prices exactly as printed. Do not include totals,
            VAT, payment or change lines. Pick each item's category from this list: \(FinanceCategories.budgetable.joined(separator: ", ")).
            """)
        do {
            let response = try await session.respond(to: "Receipt text:\n\(parsed.rawText)", generating: GeneratedReceipt.self)
            return ReceiptAIMerge.merge(response.content.reading, into: parsed)
        } catch {
            return parsed
        }
        #else
        return parsed
        #endif
    }
}

#if canImport(FoundationModels)
@Generable
struct GeneratedReceipt {
    @Guide(description: "The shop or restaurant name")
    var merchant: String?
    @Guide(description: "The purchase date exactly as printed, for example 12/10/2026")
    var date: String?
    @Guide(description: "The subtotal before VAT, if printed")
    var subtotal: Double?
    @Guide(description: "The VAT amount, if printed")
    var vat: Double?
    @Guide(description: "The total paid")
    var total: Double?
    var items: [GeneratedItem]

    var reading: ReceiptAIReading {
        ReceiptAIReading(
            merchant: merchant,
            date: date,
            subtotal: subtotal.map(Self.money),
            vat: vat.map(Self.money),
            total: total.map(Self.money),
            items: items.map { ReceiptAIReading.Item(name: $0.name, amount: Self.money($0.price), category: $0.category) }
        )
    }

    /// Model numbers arrive as Double; round to pennies before comparing with the receipt.
    static func money(_ value: Double) -> Decimal {
        Decimal(string: String(format: "%.2f", value)) ?? 0
    }
}

@Generable
struct GeneratedItem {
    @Guide(description: "The item name as printed")
    var name: String
    @Guide(description: "The item's final price")
    var price: Double
    @Guide(description: "One category from the list in the instructions")
    var category: String?
}
#endif
