import BudgetCore
import SwiftUI

/// The iPhone's Overview: the Mac Command centre on one short page. Key numbers, how the
/// month is pacing, what needs you and the next 7 days. Everything else is a tab away, and
/// the places that have no tab (To Check, Reports, Net worth) are one row near the top.
struct HomeView: View {
    @EnvironmentObject var store: BudgetStore
    /// Where a "Needs you" row leads, pushed on top of Home.
    @State private var destination: AppSection?

    var body: some View {
        let report = store.monthReport
        ScrollView {
            VStack(spacing: 14) {
                HouseholdSwitcher()
                HStack {
                    AccountFilterMenu()
                    Spacer()
                    MonthSwitcher()
                }
                MorePlacesRow()
                if store.selectedMonthIsEmpty {
                    // Budgets and averages alone aren't what happened: say there's nothing yet.
                    EmptyMonthNotice()
                } else {
                    OverviewKeyNumbers(report: report)
                    SpendingPacePanel(report: report)
                }
                NeedsYouPanel(open: { destination = $0 }, limit: 3)
                NextDaysPanel()
                GoalsPanel()
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { CategorisingBanner().padding(.bottom, 8) }
        .appBackground()
        .navigationTitle("Home")
        .navigationDestination(item: $destination) { $0.screen }
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
}

/// One row of the Mac sidebar's places that have no iPhone tab: To Check, Reports and Net worth.
struct MorePlacesRow: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        HStack(spacing: 10) {
            ForEach([AppSection.inbox, .reports, .netWorth]) { place in
                NavigationLink { place.screen } label: {
                    VStack(spacing: 6) {
                        Image(systemName: place.macSymbol)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.brandPlum)
                            .frame(height: 22)
                        Text(place.macTitle)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if place == .inbox, !store.needsReview.isEmpty {
                            Text("\(store.needsReview.count)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.brandPink, in: Capsule())
                                .padding(6)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(place == .inbox && !store.needsReview.isEmpty ? "\(place.macTitle), \(store.needsReview.count) items" : place.macTitle)
            }
        }
    }
}
