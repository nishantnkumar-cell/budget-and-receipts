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

/// The app's places, in workflow order: capture, check, see where money went, plan ahead.
enum AppSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case inbox = "Inbox"
    case activity = "Activity"
    case budgets = "Budgets"
    case plan = "Plan"
    case reports = "Reports"
    case netWorth = "Net worth"
    case scan = "Scan"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .inbox: "tray"
        case .activity: "list.bullet"
        case .budgets: "chart.bar"
        case .plan: "calendar"
        case .reports: "chart.pie"
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .scan: "doc.viewfinder"
        case .settings: "gearshape"
        }
    }

    @MainActor @ViewBuilder var screen: some View {
        switch self {
        case .home: HomeView()
        case .inbox: InboxView()
        case .activity: TransactionsView()
        case .budgets: BudgetsView()
        case .plan: PlanView()
        case .reports: ReportsView()
        case .netWorth: NetWorthView()
        case .scan: CaptureView()
        case .settings: SettingsView()
        }
    }
}

extension AppSection {
    /// Longer names for places, used in the Mac sidebar and the iPhone's "More places" row.
    var macTitle: String {
        switch self {
        case .home: "Overview"
        case .inbox: "To Check"
        case .plan: "Bills and Subscriptions"
        default: rawValue
        }
    }

    var macSymbol: String {
        switch self {
        case .home: "square.grid.2x2"
        case .inbox: "doc.text.magnifyingglass"
        case .activity: "list.bullet.rectangle"
        case .budgets: "chart.bar.xaxis"
        case .plan: "calendar.badge.clock"
        default: systemImage
        }
    }
}

#if os(iOS)
/// Four tabs plus Scan, which iOS draws as its own round button beside the tab bar.
/// To Check, Reports and Net worth open from a row on Home, and Settings from Home's toolbar.
struct PhoneRootView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var selection = AppSection.home

    var body: some View {
        TabView(selection: $selection) {
            ForEach([AppSection.home, .activity, .budgets, .plan]) { section in
                Tab(section.rawValue, systemImage: section.systemImage, value: section) {
                    NavigationStack { section.screen }
                }
                .badge(section == .home ? store.needsReview.count : 0)
            }
            Tab(AppSection.scan.rawValue, systemImage: AppSection.scan.systemImage, value: AppSection.scan, role: .search) {
                NavigationStack { CaptureView() }
            }
        }
    }
}
#endif
