import BudgetCore
import SwiftUI

/// The iPhone's Overview: the Mac Command centre on one short page. Key numbers, how the
/// month is pacing, what needs you and the next 7 days. Everything else is a tab away.
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
                if store.selectedMonthIsEmpty {
                    // Budgets and averages alone aren't what happened: say there's nothing yet.
                    EmptyMonthNotice()
                } else {
                    OverviewKeyNumbers(report: report)
                    SpendingPacePanel(report: report)
                }
                NeedsYouPanel(open: { destination = $0 }, limit: 3)
                NextDaysPanel()
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
