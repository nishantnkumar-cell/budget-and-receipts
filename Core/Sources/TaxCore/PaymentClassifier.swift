import BudgetCore
import Foundation

/// What one payment means for tax: the same answer the figures and the screens use.
public enum PaymentStatus: Hashable, Sendable {
    public enum Source: Hashable, Sendable { case byHand, byRule }
    /// One part of a split payment that belongs to a property.
    public struct Part: Hashable, Sendable {
        public var split: TransactionSplit
        public var propertyID: String
        public var category: PropertyCategory
    }

    case notProperty
    case assigned(propertyID: String, category: PropertyCategory, source: Source)
    /// A split payment with at least one part chosen. Other parts aren't property money.
    case parts([Part])
    /// The reason reads on from the payment's name, e.g. "is tagged … but has no tax category yet."
    case needsReview(String)
}

public enum PaymentClassifier {
    /// A choice made by hand wins, then the first matching rule. A tag names the property but
    /// not the kind of cost, so a tag alone needs a person to look. A split payment is only
    /// counted part by part.
    public static func classify(_ payment: BankTransaction, book: PropertyBook,
                                assignments: [String: TaxAssignment]? = nil) -> PaymentStatus {
        let choices = assignments ?? index(book.assignments)
        if !payment.splits.isEmpty {
            let parts = payment.splits.compactMap { split in
                choices[TaxAssignment(fingerprint: payment.fingerprint, splitID: split.id, propertyID: "", category: .ignore).id]
                    .map { PaymentStatus.Part(split: split, propertyID: $0.propertyID, category: $0.category) }
            }
            if !parts.isEmpty { return .parts(parts) }
        }
        if let chosen = choices[payment.fingerprint] {
            if !payment.splits.isEmpty && chosen.category != .ignore {
                return .needsReview("is split. Choose the property for each part.")
            }
            return .assigned(propertyID: chosen.propertyID, category: chosen.category, source: .byHand)
        }
        let tagged = book.properties.filter { isTagged(payment, for: $0) }
        let rule = book.rules.first { $0.matches(payment) }
        if !payment.splits.isEmpty {
            return rule != nil || !tagged.isEmpty ? .needsReview("is split. Choose the property for each part.") : .notProperty
        }
        if tagged.count > 1 { return .needsReview("is tagged with more than one property.") }
        if let rule {
            if let property = tagged.first, property.id != rule.propertyID {
                return .needsReview("has a tag and a rule that name different properties.")
            }
            return .assigned(propertyID: rule.propertyID, category: rule.category, source: .byRule)
        }
        if let property = tagged.first { return .needsReview("is tagged \(property.name) but has no tax category yet.") }
        return .notProperty
    }

    public static func index(_ assignments: [TaxAssignment]) -> [String: TaxAssignment] {
        Dictionary(assignments.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    static func isTagged(_ payment: BankTransaction, for property: RentalProperty) -> Bool {
        (payment.tags ?? []).contains { $0.compare(PropertyLedger.tag(for: property), options: .caseInsensitive) == .orderedSame }
    }
}
