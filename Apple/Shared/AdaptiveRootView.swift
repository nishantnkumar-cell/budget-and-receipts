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
        case .scan: CaptureView()
        case .settings: SettingsView()
        }
    }
}

#if os(iOS)
/// Four tabs plus Scan, which iOS draws as its own round button beside the tab bar.
/// The Inbox opens from Home, and Settings from Home's toolbar.
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
