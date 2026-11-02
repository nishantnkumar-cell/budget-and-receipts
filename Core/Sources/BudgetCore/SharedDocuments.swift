import Foundation

/// A file someone shared or opened with the app, and what became of it, so nothing
/// shared ever disappears without a trace.
public struct SharedDocument: Identifiable, Codable, Hashable, Sendable {
    public enum Outcome: Codable, Hashable, Sendable {
        /// Imported as a bank or card statement.
        case statement(imported: Int, alreadyThere: Int, totalsDifference: Decimal?)
        /// Read as a receipt, now in Waiting for payment (or matched to a payment).
        case receipt(pendingID: UUID)
        /// Not read. The reason is in plain words.
        case failed(reason: String)
    }

    public var id: UUID
    public var fileName: String
    public var receivedAt: Date
    public var outcome: Outcome
    /// A copy of the original file kept in the app, so it can be read again another way.
    public var storedFile: String?

    public init(id: UUID = UUID(), fileName: String, receivedAt: Date = Date(), outcome: Outcome, storedFile: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.receivedAt = receivedAt
        self.outcome = outcome
        self.storedFile = storedFile
    }

    /// One line on what happened, for lists and confirmations.
    public var summary: String {
        switch outcome {
        case .statement(let imported, let alreadyThere, let difference):
            var text = "Imported as a statement: \(imported) payment\(imported == 1 ? "" : "s")"
            if alreadyThere > 0 { text += ", \(alreadyThere) already there" }
            if difference != nil { text += ". Totals don't match the statement, so check it" }
            return text
        case .receipt:
            return "Read as a receipt"
        case .failed(let reason):
            return "Couldn't read: \(reason)"
        }
    }

    public var needsAttention: Bool {
        switch outcome {
        case .statement(_, _, let difference): difference != nil
        case .receipt: false
        case .failed: true
        }
    }
}
