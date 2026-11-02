import Foundation

public enum SplitApprovalFailure: Error, Equatable, Sendable {
    case noItems
    case notReviewed
    case invalidItem(Int)
    case uncategorised(Int)
    case unbalanced
}

public struct SplitApprovalPolicy: Sendable {
    /// Splits are stored as positive allocation magnitudes. The bank transaction may be
    /// negative for a purchase/debit or positive for a refund/credit.
    public var tolerance = Decimal(string: "0.005")!

    public init() {}

    public func validate(_ draft: SplitDraft, bankAmount: Decimal, reviewed: Bool) -> Result<Void, SplitApprovalFailure> {
        guard !draft.proposedSplits.isEmpty else { return .failure(.noItems) }
        guard reviewed else { return .failure(.notReviewed) }

        for (index, item) in draft.proposedSplits.enumerated() {
            guard !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.amount > 0 else {
                return .failure(.invalidItem(index))
            }
            guard item.category != "Uncategorised", !item.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.uncategorised(index))
            }
        }

        let difference = decimalAbsolute(decimalAbsolute(bankAmount) - draft.splitTotal)
        return difference <= tolerance ? .success(()) : .failure(.unbalanced)
    }

    private func decimalAbsolute(_ value: Decimal) -> Decimal { value < 0 ? -value : value }
}
