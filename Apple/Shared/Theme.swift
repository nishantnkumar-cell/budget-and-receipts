import BudgetCore
import SwiftUI

/// Shared look for every screen: white cards on a warm page, in the Chitra palette.
/// Colours come from Assets.xcassets (built by Design/logo/make_icons.py).
enum Theme {
    static let cornerRadius: CGFloat = 20
    static let spacing: CGFloat = 16
}

extension Decimal {
    /// Formats money in the currency chosen in Settings.
    var money: String { formatted(.currency(code: AppSettings.currency)) }

    /// Whole pounds (or dollars), for big numbers like net worth where pence are noise.
    var wholeMoney: String { formatted(.currency(code: AppSettings.currency).precision(.fractionLength(0))) }
}

extension View {
    /// A white rounded card, the building block of every screen.
    func card(padding: CGFloat = Theme.spacing) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    /// The warm page colour behind the cards.
    func appBackground() -> some View {
        background(Color.screenBackground.ignoresSafeArea())
    }
}

/// Section title above a card, with an optional trailing link.
struct CardHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            trailing.font(.subheadline)
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Small rounded label for a category.
struct CategoryChip: View {
    let category: String

    var body: some View {
        Text(category)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(Color.brandPlum)
            .background(Color.brandPlum.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Category name, amount left and a progress bar, used on Home and Budgets.
struct BudgetProgressRow: View {
    let line: CategoryBudgetLine

    private var tint: Color {
        guard let progress = line.progress else { return .secondary }
        if progress > 1 { return .red }
        if progress > 0.85 { return .brandAmber }
        return .brandPink
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(line.category).font(.body.weight(.semibold))
                    .foregroundStyle(line.isOverBudget ? Color.red : Color.primary)
                if line.isTentative {
                    Label("Tentative", systemImage: "wand.and.stars")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color.brandPlum)
                        .background(Color.brandPlum.opacity(0.12), in: Capsule())
                        .help("Your 3-month average. Set a budget to replace it.")
                }
                Spacer()
                if let remaining = line.remaining, let limit = line.limit {
                    if remaining < 0 {
                        Text("\((-remaining).money) over").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    } else {
                        Text("\(remaining.money) left").font(.subheadline.weight(.semibold))
                            + Text(" of \(limit.money)").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(line.spent.money) spent").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            if let progress = line.progress {
                ProgressView(value: min(progress, 1)).tint(tint)
            } else {
                Text("No limit set").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One transaction: merchant, category and amount; money in shows in green.
struct TransactionRow: View {
    @EnvironmentObject var store: BudgetStore
    let transaction: BankTransaction

    var body: some View {
        HStack(spacing: 12) {
            Text(String(transaction.merchant.prefix(1)).uppercased())
                .font(.headline)
                .frame(width: 40, height: 40)
                .foregroundStyle(Color.brandPlum)
                .background(Color.brandPlum.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchant).font(.body.weight(.semibold)).lineLimit(1)
                if transaction.pendingSplitDraft != nil {
                    Text("Receipt waiting for approval").font(.caption).foregroundStyle(Color.brandAmber)
                } else {
                    HStack(spacing: 6) {
                        if transaction.splits.isEmpty {
                            Text(FinanceCategories.label(transaction.category, transaction.subcategory)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            // Split by its receipt's items: show where the parts went.
                            Label(Array(Set(transaction.splits.map(\.category))).sorted().joined(separator: ", "), systemImage: "square.split.2x1")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if store.hasPartner {
                            OwnerChip(owner: store.ledger.owner(of: transaction), partnerName: store.couple.partnerName)
                        }
                    }
                }
            }
            Spacer()
            Text(transaction.amount.money)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(transaction.amount < 0 ? Color.primary : Color.green)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "‹ November 2026 ›" control that changes the month shown on Home and Budgets.
struct MonthSwitcher: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        HStack(spacing: 4) {
            Button { store.moveMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Text(store.selectedMonth, format: .dateTime.month(.abbreviated).year())
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 80)
            Button { store.moveMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next month")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.small)
    }
}

extension CategoryColor {
    /// Category colours on the Graphite and violet theme: the brand colours first, then
    /// system colours that read well on light and dark.
    var swatch: Color {
        switch self {
        case .violet: .brandPlum
        case .magenta: .brandPartner
        case .teal: .brandTeal
        case .amber: .brandAmber
        case .pink: .brandPink
        case .green: .green
        case .blue: .blue
        case .orange: .orange
        case .red: .red
        case .indigo: .indigo
        case .mint: .mint
        case .brown: .brown
        case .graphite: .gray
        }
    }
}
