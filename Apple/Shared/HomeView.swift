import BudgetCore
import SwiftUI

/// The first screen: what's left to spend, receipts waiting, budgets and bills coming up.
struct HomeView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore

    var body: some View {
        let report = store.monthReport
        ScrollView {
            VStack(spacing: Theme.spacing) {
                HouseholdSwitcher()
                HStack {
                    AccountFilterMenu()
                    Spacer()
                    MonthSwitcher()
                }
                if store.selectedMonthIsEmpty {
                    // Budgets and averages alone aren't what happened: say there's nothing yet.
                    EmptyMonthNotice()
                } else {
                    LeftToSpendCard(report: report, month: store.selectedMonth,
                                    safeToSpend: store.safeToSpend(contracts: subscriptions.contracts),
                                    coverageNote: store.coverageNote)
                    BalanceForecastLine()
                }
                CoupleBalanceCard()
                AccountSpendingCard()
                if !store.needsReview.isEmpty {
                    NavigationLink { InboxView() } label: { InboxSummaryCard(count: store.needsReview.count) }
                        .buttonStyle(.plain)
                }
                // Shared statements wait here to be reviewed, even when the Inbox has nothing else.
                SharedDocumentsBanner(onHome: true)
                if !store.selectedMonthIsEmpty { topBudgets(report) }
                ComingUpCard()
                NetWorthCard()
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { CategorisingBanner().padding(.bottom, 8) }
        .appBackground()
        .navigationTitle("Home")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SyncStatusButton() }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        #endif
    }

    @ViewBuilder private func topBudgets(_ report: MonthlyBudgetReport) -> some View {
        let lines = report.lines
            .filter { $0.limit != nil }
            .sorted { ($0.progress ?? 0) > ($1.progress ?? 0) }
            .prefix(3)
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Budgets") {
                NavigationLink("See all") { BudgetsView() }
            }
            if lines.isEmpty {
                Text("Set monthly limits on Budgets to see what's left in each category.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(lines)) { BudgetProgressRow(line: $0) }
        }
        .card()
    }
}

/// The indigo card at the top of Home. Shows money left in the month's budgets,
/// or plain spending when no budgets are set yet.
struct LeftToSpendCard: View {
    let report: MonthlyBudgetReport
    let month: Date
    var safeToSpend: SafeToSpend?
    /// "Payments up to 22 Oct" while the month's statements are incomplete.
    var coverageNote: String?

    private var budgeted: Decimal { report.lines.compactMap(\.limit).reduce(0, +) }
    private var spentInBudgets: Decimal { report.lines.filter { $0.limit != nil }.reduce(0) { $0 + $1.spent } }
    private var progress: Double {
        guard budgeted > 0 else { return 0 }
        return min(NSDecimalNumber(decimal: spentInBudgets / budgeted).doubleValue, 1)
    }

    private var daysLeft: Int? {
        let calendar = Calendar.current
        guard calendar.isDate(month, equalTo: Date(), toGranularity: .month),
              let range = calendar.range(of: .day, in: .month, for: Date()) else { return nil }
        return range.count - calendar.component(.day, from: Date())
    }

    var body: some View {
        HStack(spacing: Theme.spacing) {
            VStack(alignment: .leading, spacing: 4) {
                if budgeted > 0 {
                    Text("Left to spend").font(.subheadline).opacity(0.8)
                    Text((budgeted - spentInBudgets).money)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text(subtitle).font(.subheadline).opacity(0.8)
                    if let coverageNote {
                        Label(coverageNote, systemImage: "calendar").font(.caption).opacity(0.7)
                    }
                    if let safeToSpend {
                        Text("\(safeToSpend.today.money) safe to spend today")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.heroAccent)
                            .padding(.top, 4)
                    }
                } else {
                    Text("Spent this month").font(.subheadline).opacity(0.8)
                    Text(report.spending.money)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    Text("Income \(report.income.money)").font(.subheadline).opacity(0.8)
                    if let coverageNote {
                        Label(coverageNote, systemImage: "calendar").font(.caption).opacity(0.7)
                    }
                }
            }
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            Spacer(minLength: 0)
            if budgeted > 0 {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.heroAccent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.subheadline.weight(.bold))
                }
                .frame(width: 80, height: 80)
                .accessibilityLabel("\(Int(progress * 100)) percent of budget spent")
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.heroBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if let daysLeft { "of \(budgeted.money) · \(daysLeft) days to go" } else { "of \(budgeted.money)" }
    }
}

/// "3 receipts to check" card that opens the Inbox.
struct InboxSummaryCard: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(Color.brandPink)
                .frame(width: 40, height: 40)
                .background(Color.brandPink.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(count == 1 ? "1 item to check" : "\(count) items to check").font(.body.weight(.semibold))
                Text("Receipts and payments waiting for your OK").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .card(padding: 14)
        .contentShape(Rectangle())
    }
}
