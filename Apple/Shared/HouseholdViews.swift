import BudgetCore
import SwiftUI

extension HouseholdView {
    func label(partnerName: String) -> String {
        switch self {
        case .me: "Me"
        case .partner: partnerName.isEmpty ? "Partner" : partnerName
        case .together: "Together"
        }
    }

    /// Whether a transaction with this owner shows in this view's Activity list.
    func includes(_ owner: MoneyOwner) -> Bool {
        switch (self, owner) {
        case (.together, _), (_, .shared), (.me, .mine), (.partner, .partner): true
        default: false
        }
    }
}

/// The Me / Partner / Together switch. Shows nothing for a single person.
struct HouseholdSwitcher: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        if store.hasPartner {
            Picker("Show", selection: $store.householdView) {
                ForEach(HouseholdView.allCases, id: \.self) { view in
                    Text(view.label(partnerName: store.couple.partnerName)).tag(view)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// Home: who owes whom, with a button to record that it's been paid back.
struct CoupleBalanceCard: View {
    @EnvironmentObject var store: BudgetStore
    @State private var confirming = false

    var body: some View {
        if store.hasPartner {
            let balance = store.coupleBalance
            let partner = store.couple.partnerName
            HStack(spacing: 12) {
                IconBadge(systemImage: balance.debtor == nil ? "checkmark" : "arrow.left.arrow.right",
                          tint: balance.debtor == nil ? .green : .brandPink)
                VStack(alignment: .leading, spacing: 2) {
                    switch balance.debtor {
                    case .partner:
                        Text("\(partner) owes you").font(.subheadline).foregroundStyle(.secondary)
                        Text(balance.amountOwed.money).font(.title3.weight(.bold)).monospacedDigit()
                    case .me:
                        Text("You owe \(partner)").font(.subheadline).foregroundStyle(.secondary)
                        Text(balance.amountOwed.money).font(.title3.weight(.bold)).monospacedDigit()
                    case nil:
                        Text("You and \(partner) are all square").font(.body.weight(.semibold))
                        Text("Shared costs are split \(sharePercent)/\(100 - sharePercent)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if balance.debtor != nil {
                    Button("Settle up") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.brandPink)
                }
            }
            .card()
            .confirmationDialog("Mark \(balance.amountOwed.money) as paid back?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Settled Up") { store.settleUp() }
            } message: {
                Text("Do this once the money has actually been sent. The balance goes back to zero.")
            }
        }
    }

    private var sharePercent: Int { NSDecimalNumber(decimal: store.couple.myShare * 100).intValue }
}

/// "Mine", "Shared" or the partner's name on an Activity row.
struct OwnerChip: View {
    let owner: MoneyOwner
    let partnerName: String

    var body: some View {
        Text(owner.label(partnerName: partnerName))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var tint: Color {
        switch owner {
        case .mine: .brandPlum
        case .partner: .brandPink
        case .shared: .brandAmber
        }
    }
}

/// A symbol in a softly tinted circle, the icon style used across cards and lists.
struct IconBadge: View {
    let systemImage: String
    var tint: Color = .brandPlum
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}
