import BudgetCore
import SwiftUI

/// "↑ £2.00" next to a bill whose last payment went up.
struct PriceRiseChip: View {
    let rise: PriceRise
    let currency: String

    var body: some View {
        Label(rise.increase.formatted(.currency(code: currency)), systemImage: "arrow.up")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.red)
            .background(Color.red.opacity(0.1), in: Capsule())
            .accessibilityLabel("Price went up by \(rise.increase.formatted(.currency(code: currency)))")
    }
}

/// One amber line on a receipt that looks like one already added. Nothing when it doesn't.
struct DuplicateReceiptBanner: View {
    let warning: String?

    var body: some View {
        if let warning {
            Label(warning, systemImage: "doc.on.doc")
                .font(.subheadline)
                .foregroundStyle(Color.orange)
        }
    }
}

/// When to be reminded before a bill is due. Nil means the default of 2 days; 0 is off.
struct ReminderPicker: View {
    @Binding var daysBefore: Int?

    var body: some View {
        Picker("Remind me", selection: Binding(get: { daysBefore ?? 2 }, set: { daysBefore = $0 == 2 ? nil : $0 })) {
            Text("Off").tag(0)
            Text("1 day before").tag(1)
            Text("2 days before").tag(2)
            Text("3 days before").tag(3)
            Text("1 week before").tag(7)
        }
    }
}

extension CoupleLedger.OwnerSource {
    /// Why a transaction has the owner it has, for the transaction detail footer.
    func explanation(accountName: String?) -> String {
        switch self {
        case .manual: "Set by you."
        case .account: "From the account it was paid from\(accountName.map { ", \($0)" } ?? "")."
        case .merchantRule: "From your rule for this shop."
        case .categoryRule: "From your rule for this category."
        case .default: "Your default for everything else."
        }
    }
}
