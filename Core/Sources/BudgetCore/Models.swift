import Foundation

public struct BankTransaction: Identifiable, Codable, Hashable, Sendable {
    public var id: String { fingerprint }
    public var date: Date
    public var merchant: String
    public var description: String
    public var amount: Decimal
    public var category: String
    public var fingerprint: String
    public var splits: [TransactionSplit]
    public var pendingSplitDraft: SplitDraft?

    public init(
        date: Date,
        merchant: String,
        description: String = "",
        amount: Decimal,
        category: String = "Uncategorised",
        fingerprint: String,
        splits: [TransactionSplit] = [],
        pendingSplitDraft: SplitDraft? = nil
    ) {
        self.date = date
        self.merchant = merchant
        self.description = description
        self.amount = amount
        self.category = category
        self.fingerprint = fingerprint
        self.splits = splits
        self.pendingSplitDraft = pendingSplitDraft
    }
}

public struct TransactionSplit: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var category: String
    public var amount: Decimal

    public init(id: UUID = UUID(), label: String, category: String, amount: Decimal) {
        self.id = id
        self.label = label
        self.category = category
        self.amount = amount
    }
}

public struct ReceiptLineItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var description: String
    public var total: Decimal
    public var category: String
    public var confidence: Double

    public init(id: UUID = UUID(), description: String, total: Decimal, category: String = "Uncategorised", confidence: Double) {
        self.id = id
        self.description = description
        self.total = total
        self.category = category
        self.confidence = confidence
    }
}

public struct ReceiptRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var imagePath: String
    public var merchant: String
    public var purchaseDate: Date?
    public var subtotal: Decimal?
    public var tax: Decimal?
    public var total: Decimal?
    public var rawText: String
    public var items: [ReceiptLineItem]
    public var confidence: Double
    public var reviewed: Bool

    public init(
        id: UUID = UUID(),
        imagePath: String,
        merchant: String,
        purchaseDate: Date?,
        subtotal: Decimal?,
        tax: Decimal?,
        total: Decimal?,
        rawText: String,
        items: [ReceiptLineItem],
        confidence: Double,
        reviewed: Bool = false
    ) {
        self.id = id
        self.imagePath = imagePath
        self.merchant = merchant
        self.purchaseDate = purchaseDate
        self.subtotal = subtotal
        self.tax = tax
        self.total = total
        self.rawText = rawText
        self.items = items
        self.confidence = confidence
        self.reviewed = reviewed
    }
}

public struct SplitDraft: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var receipt: ReceiptRecord
    public var proposedSplits: [TransactionSplit]
    public var createdAt: Date
    public var approvedAt: Date?

    public var splitTotal: Decimal { proposedSplits.reduce(0) { $0 + $1.amount } }

    public init(id: UUID = UUID(), receipt: ReceiptRecord, proposedSplits: [TransactionSplit], createdAt: Date = Date(), approvedAt: Date? = nil) {
        self.id = id
        self.receipt = receipt
        self.proposedSplits = proposedSplits
        self.createdAt = createdAt
        self.approvedAt = approvedAt
    }
}

public struct ChangeRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public let date: Date
    public let transactionID: String
    public let reason: String

    public init(id: UUID = UUID(), date: Date, transactionID: String, reason: String) {
        self.id = id
        self.date = date
        self.transactionID = transactionID
        self.reason = reason
    }
}
