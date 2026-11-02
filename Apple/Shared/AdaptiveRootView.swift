import SwiftUI

struct AdaptiveRootView: View {
    var body: some View {
        #if os(iOS)
        PhoneRootView()
        #else
        MacRootView()
        #endif
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case transactions = "Transactions"
    case budgets = "Budgets"
    case recurring = "Recurring"
    case review = "Review"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: "chart.pie.fill"
        case .transactions: "list.bullet.rectangle"
        case .budgets: "gauge.with.dots.needle.67percent"
        case .recurring: "repeat.circle"
        case .review: "checklist"
        }
    }

    @MainActor @ViewBuilder var screen: some View {
        switch self {
        case .overview: OverviewView()
        case .transactions: TransactionsView()
        case .budgets: BudgetsView()
        case .recurring: RecurringView()
        case .review: ReviewView()
        }
    }
}

#if os(iOS)
struct PhoneRootView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var selection = AppSection.overview

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                NavigationStack { section.screen }
                    .tabItem { Label(section.rawValue, systemImage: section.systemImage) }
                    .badge(section == .review ? store.needsReview.count : 0)
                    .tag(section)
            }
        }
    }
}
#endif

#if os(macOS)
struct MacRootView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var selection: AppSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .badge(section == .review ? store.needsReview.count : 0)
                    .tag(section)
            }
            .navigationTitle("Budget & Receipts")
        } detail: {
            NavigationStack { (selection ?? .overview).screen }
        }
    }
}
#endif
