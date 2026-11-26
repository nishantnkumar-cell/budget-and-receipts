import BudgetCore
import Foundation

/// Changes to the property book that must keep it consistent.
extension PropertyBook {
    public var isEmpty: Bool { self == PropertyBook() }

    /// Marks one payment by hand, replacing any choice for it or its parts.
    public mutating func assign(_ payment: BankTransaction, to propertyID: String, as category: PropertyCategory) {
        assignments.removeAll { $0.fingerprint == payment.fingerprint }
        assignments.append(TaxAssignment(fingerprint: payment.fingerprint, propertyID: propertyID, category: category, paymentDate: payment.date))
    }

    /// Marks one part of a split payment. Nil takes that part out. Choices for the whole
    /// payment, or for parts that no longer exist, are dropped.
    public mutating func assign(part splitID: UUID, of payment: BankTransaction, to choice: (propertyID: String, category: PropertyCategory)?) {
        let current = Set(payment.splits.map(\.id))
        assignments.removeAll { assignment in
            guard assignment.fingerprint == payment.fingerprint else { return false }
            guard let part = assignment.splitID else { return true }
            return part == splitID || !current.contains(part)
        }
        if let choice {
            assignments.append(TaxAssignment(fingerprint: payment.fingerprint, splitID: splitID, propertyID: choice.propertyID,
                                             category: choice.category, paymentDate: payment.date))
        }
    }

    /// "Always treat this shop or person this way." Replaces any rule for the same text and is
    /// tried before older rules. The payment's own hand choice is dropped.
    public mutating func addRule(from payment: BankTransaction, to propertyID: String, as category: PropertyCategory,
                                 isPrivate: Bool = false, now: Date = Date()) {
        let text = payment.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return assign(payment, to: propertyID, as: category) }
        rules.removeAll { $0.merchantContains.compare(text, options: .caseInsensitive) == .orderedSame }
        let newest = max(now.timeIntervalSince1970.rounded(), (rules.map(\.added).max() ?? 0) + 1)
        rules.insert(PropertyRule(merchantContains: text, propertyID: propertyID, category: category,
                                  added: newest, isPrivate: isPrivate), at: 0)
        assignments.removeAll { $0.fingerprint == payment.fingerprint }
    }

    /// Takes a payment out of the property figures. If a rule or tag would pull it back in,
    /// it is marked "Not for tax" instead.
    public mutating func exclude(_ payment: BankTransaction) {
        assignments.removeAll { $0.fingerprint == payment.fingerprint }
        guard PaymentClassifier.classify(payment, book: self) != .notProperty else { return }
        let tagged = properties.first { PaymentClassifier.isTagged(payment, for: $0) }
        let propertyID = rules.first { $0.matches(payment) }?.propertyID ?? tagged?.id
        if let propertyID { assign(payment, to: propertyID, as: .ignore) }
    }

    /// A payment logged on the phone met its statement line: choices follow it.
    public mutating func replacePayment(_ old: String, with new: String) {
        let moved = assignments.filter { $0.fingerprint == old }
        if !moved.isEmpty {
            assignments.removeAll { $0.fingerprint == old }
            if !assignments.contains(where: { $0.fingerprint == new }) {
                assignments += moved.map { assignment in
                    var next = assignment
                    next.fingerprint = new
                    return next
                }
            }
        }
        for index in statements.indices where statements[index].bankFingerprint == old {
            statements[index].bankFingerprint = new
        }
    }

    /// Removes a property and everything entered for it.
    public mutating func removeProperty(_ id: String) {
        properties.removeAll { $0.id == id }
        rules.removeAll { $0.propertyID == id }
        assignments.removeAll { $0.propertyID == id }
        statements.removeAll { $0.propertyID == id }
        interest.removeAll { $0.propertyID == id }
    }
}
