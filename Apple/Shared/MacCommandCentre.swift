#if os(macOS)
import BudgetCore
import Charts
import SwiftUI

/// The Mac window: a sidebar of places, people and accounts, and an Overview that shows the
/// whole month at once (key numbers, spending pace, what needs you, and recent activity).
struct MacRootView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var selection: AppSection? = .home
    @State private var showingPalette = false

    var body: some View {
        NavigationSplitView {
            MacSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            NavigationStack {
                switch selection ?? .home {
                case .home: MacOverview(selection: $selection)
                case let section: section.screen
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { selection = .scan } label: { Label("Add Receipt", systemImage: "doc.viewfinder") }
                        .help("Scan or choose a receipt")
                }
            }
            .background {
                // ⌘K: jump anywhere or find any payment.
                Button("Go To…") { showingPalette = true }
                    .keyboardShortcut("k", modifiers: .command)
                    .hidden()
            }
            .sheet(isPresented: $showingPalette) {
                CommandPalette(selection: $selection)
                    .frame(width: 560, height: 420)
            }
        }
        .tint(.brandPink)
        .frame(minWidth: 1080, minHeight: 720)
    }
}

// MARK: Command palette

/// ⌘K: type to jump to a place or find a payment by shop, category, tag or amount.
struct CommandPalette: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: AppSection?
    @State private var query = ""
    @State private var editing: BankTransaction?
    @FocusState private var focused: Bool

    private var places: [AppSection] {
        [AppSection.home, .activity, .inbox, .budgets, .plan, .netWorth, .scan, .settings].filter {
            query.isEmpty || $0.macTitle.localizedCaseInsensitiveContains(query) || $0.rawValue.localizedCaseInsensitiveContains(query)
        }
    }

    private var payments: [BankTransaction] {
        guard query.count >= 2 else { return [] }
        let amount = Decimal(string: query.replacingOccurrences(of: "£", with: ""))
        return store.transactions.filter { transaction in
            transaction.merchant.localizedCaseInsensitiveContains(query)
                || FinanceCategories.label(transaction.category, transaction.subcategory).localizedCaseInsensitiveContains(query)
                || (transaction.tags ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
                || amount.map { abs(transaction.amount) == $0 } == true
        }
        .sorted { $0.date > $1.date }
        .prefix(30)
        .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a place, or find a shop, category, tag or amount", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(openFirst)
            }
            .padding(14)
            Divider()
            List {
                if !places.isEmpty {
                    Section("Go to") {
                        ForEach(places) { place in
                            Button {
                                selection = place
                                dismiss()
                            } label: {
                                Label(place.macTitle, systemImage: place.macSymbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !payments.isEmpty {
                    Section("Payments") {
                        ForEach(payments) { payment in
                            Button { editing = payment } label: {
                                HStack {
                                    Text(payment.date, format: .dateTime.day().month(.abbreviated)).foregroundStyle(.secondary).monospacedDigit().frame(width: 56, alignment: .leading)
                                    Text(payment.merchant).lineLimit(1)
                                    Spacer()
                                    Text(FinanceCategories.label(payment.category, payment.subcategory)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(payment.amount.money).monospacedDigit().fontWeight(.semibold)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
        .sheet(item: $editing) { transaction in
            NavigationStack { TransactionEditor(transaction: transaction) }
                .frame(minWidth: 460, minHeight: 520)
        }
    }

    private func openFirst() {
        if let place = places.first, payments.isEmpty {
            selection = place
            dismiss()
        } else if let payment = payments.first {
            editing = payment
        }
    }
}

// MARK: Sidebar

extension AppSection {
    /// The Mac sidebar's names, which say a little more than the iPhone's tab titles.
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

struct MacSidebar: View {
    @EnvironmentObject var store: BudgetStore
    @Binding var selection: AppSection?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach([AppSection.home, .activity, .inbox, .budgets, .plan, .netWorth]) { section in
                    Label(section.macTitle, systemImage: section.macSymbol)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
            Section("People") {
                if store.hasPartner {
                    personRow(.me, name: myName, symbol: "person.fill")
                    personRow(.partner, name: store.couple.partnerName, symbol: "person.fill")
                    personRow(.together, name: "Together", symbol: "person.2.fill")
                } else {
                    Label(myName, systemImage: "person.fill")
                    Button { selection = .settings } label: {
                        Label("Add Your Partner…", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.brandPink)
                    .help("Split shared costs and switch between Me, your partner and Together")
                }
            }
            if !store.accounts.isEmpty {
                Section("Accounts") {
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        Button {
                            store.accountFilter = store.accountFilter == account.id ? nil : account.id
                        } label: {
                            HStack {
                                Label {
                                    Text(account.name.isEmpty ? account.label : account.name).lineLimit(1)
                                } icon: {
                                    Image(systemName: store.accountFilter == account.id ? "creditcard.fill" : "creditcard")
                                        .foregroundStyle(OverviewPalette.series(index))
                                }
                                Spacer()
                                Text(spent(account.id).money).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Spent in \(store.selectedMonth.formatted(.dateTime.month(.wide))). Click to \(store.accountFilter == account.id ? "show all accounts" : "show only this account").")
                    }
                }
            }
            Section {
                Label(AppSection.settings.rawValue, systemImage: AppSection.settings.systemImage)
                    .tag(AppSection.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarSyncFooter() }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("Duo Budget").font(.headline)
                Spacer()
                Text("⌘K").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
                    .help("Press ⌘K to jump anywhere or find a payment")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .navigationTitle("Duo Budget")
    }

    private var myName: String {
        store.couple.ownerName.flatMap { $0.isEmpty ? nil : $0.split(separator: " ").first.map(String.init) } ?? "Me"
    }

    private func badge(for section: AppSection) -> Text? {
        switch section {
        case .inbox: store.needsReview.isEmpty ? nil : Text("\(store.needsReview.count)")
        case .activity: store.transactions.isEmpty ? nil : Text("\(store.transactions.count)")
        default: nil
        }
    }

    /// What one person spent in the month on screen, with their share of shared costs.
    private func spent(by view: HouseholdView) -> Decimal {
        let scaled = store.ledger.transactions(store.transactions, for: view)
        return store.calculator.spendingByCategory(scaled, month: store.selectedMonth).values.reduce(0, +)
    }

    private func spent(_ id: UUID) -> Decimal {
        store.spendingByAccount.first { $0.account?.id == id }?.spent ?? 0
    }

    private func personRow(_ view: HouseholdView, name: String, symbol: String) -> some View {
        Button { store.householdView = view } label: {
            HStack {
                Label {
                    Text(name)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(view == .partner ? Color.brandPartner : view == .me ? Color.brandPlum : Color.secondary)
                }
                Spacer()
                Text(spent(by: view).wholeMoney)
                    .foregroundStyle(store.householdView == view ? Color.primary : Color.secondary)
                    .fontWeight(store.householdView == view ? .semibold : .regular)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(store.householdView == view ? .isSelected : [])
    }
}

/// "Synced 2 minutes ago" at the foot of the sidebar. Hidden when sync is off.
struct SidebarSyncFooter: View {
    @EnvironmentObject var syncStatus: SyncStatus

    var body: some View {
        if syncStatus.state != .off {
            HStack(spacing: 6) {
                Image(systemName: syncStatus.state.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(syncStatus.state == .upToDate ? Color.green : syncStatus.state.color)
                    .symbolEffect(.rotate, isActive: syncStatus.state == .syncing)
                if syncStatus.state == .upToDate, let lastSynced = syncStatus.lastSynced {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Synced \(lastSynced, format: .relative(presentation: .named))")
                    }
                } else {
                    Text(syncStatus.state.title)
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: Overview

struct MacOverview: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Binding var selection: AppSection?
    @State private var query = ""

    var body: some View {
        let report = store.monthReport
        VStack(spacing: 16) {
            if store.selectedMonthIsEmpty {
                EmptyMonthNotice()
            } else {
                OverviewKeyNumbers(report: report)
            }
            HStack(alignment: .top, spacing: 16) {
                SpendingPacePanel(report: report)
                VStack(spacing: 16) {
                    NeedsYouPanel(open: { selection = $0 })
                    NextDaysPanel()
                }
                .frame(width: 340)
            }
            .frame(height: 330)
            MacRecentActivity(query: query, selection: $selection)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.screenBackground)
        .navigationTitle(store.selectedMonth.formatted(.dateTime.month(.wide).year()))
        .searchable(text: $query, placement: .toolbar, prompt: "Search shops and categories")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button { store.moveMonth(by: -1) } label: { Label("Previous Month", systemImage: "chevron.left") }
                    Button { store.moveMonth(by: 1) } label: { Label("Next Month", systemImage: "chevron.right") }
                }
                .controlGroupStyle(.navigation)
            }
            if store.hasPartner {
                ToolbarItem(placement: .principal) { HouseholdSwitcher().frame(width: 260) }
            }
            ToolbarItem(placement: .primaryAction) { SyncStatusButton() }
        }
    }
}

// MARK: Recent activity

struct MacRecentActivity: View {
    @EnvironmentObject var store: BudgetStore
    let query: String
    @Binding var selection: AppSection?
    @State private var selected: BankTransaction.ID?
    @State private var editing: BankTransaction?

    /// The month on screen, like everything else on the Overview (all months are in Activity).
    private var rows: [BankTransaction] {
        store.transactions
            .filter { store.calculator.isInMonth($0.date, store.selectedMonth) }
            .filter { store.accountFilter == nil || $0.accountID == store.accountFilter }
            .filter { !store.hasPartner || store.householdView.includes(store.ledger.owner(of: $0)) }
            .filter { query.isEmpty || $0.merchant.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
                || ($0.tags ?? []).contains { $0.localizedCaseInsensitiveContains(query) } }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        OverviewPanel(title: "\(store.selectedMonth.formatted(.dateTime.month(.wide))) activity", symbol: "list.bullet.rectangle") {
            Button("See All") { selection = .activity }.buttonStyle(.borderless)
        } content: {
            Table(rows, selection: $selected) {
                TableColumn("Date") { transaction in
                    Text(transaction.date, format: .dateTime.day().month(.abbreviated))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(min: 56, ideal: 64, max: 80)
                TableColumn("Shop") { transaction in
                    HStack(spacing: 8) {
                        Text(String(Categoriser.merchantKey(transaction.merchant).prefix(1)).ifEmpty(String(transaction.merchant.prefix(1))).uppercased())
                            .font(.caption.weight(.bold))
                            .frame(width: 22, height: 22)
                            .foregroundStyle(Color.brandPlum)
                            .background(Color.brandPlum.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)
                        Text(transaction.merchant).fontWeight(.medium).lineLimit(1)
                        if !transaction.splits.isEmpty || transaction.pendingSplitDraft != nil {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                                .help("Has a receipt")
                        }
                    }
                }
                TableColumn("Category") { transaction in
                    HStack(spacing: 6) {
                        Circle().fill(OverviewPalette.category(transaction.category)).frame(width: 7, height: 7)
                        if transaction.splits.isEmpty {
                            Text(FinanceCategories.label(transaction.category, transaction.subcategory)).lineLimit(1)
                        } else {
                            Label("Split: " + Array(Set(transaction.splits.map(\.category))).sorted().joined(separator: ", "), systemImage: "square.split.2x1")
                                .lineLimit(1)
                                .help("Split across categories by its receipt's items")
                        }
                    }
                }
                .width(min: 110, ideal: 150)
                TableColumn("Whose") { transaction in
                    if store.hasPartner {
                        OwnerChip(owner: store.ledger.owner(of: transaction), partnerName: store.couple.partnerName)
                    }
                }
                .width(min: 60, ideal: 80, max: 100)
                TableColumn("Account") { transaction in
                    Text(store.account(transaction.accountID)?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Amount") { transaction in
                    Text(transaction.amount.money)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundStyle(transaction.amount < 0 ? Color.primary : Color.green)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 80, ideal: 100)
            }
            .contextMenu(forSelectionType: BankTransaction.ID.self) { ids in
                if let id = ids.first, let transaction = store.transactions.first(where: { $0.id == id }) {
                    Button("Edit…") { editing = transaction }
                    Button("Delete", role: .destructive) { store.delete(transaction) }
                }
            } primaryAction: { ids in
                editing = ids.first.flatMap { id in store.transactions.first { $0.id == id } }
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No payments this month" : "No results",
                                           systemImage: query.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                                           description: Text(query.isEmpty ? "Import a statement for this month, or see every month in Activity." : "Try another shop or category."))
                }
            }
        }
        .frame(maxHeight: .infinity)
        .sheet(item: $editing) { transaction in
            NavigationStack { TransactionEditor(transaction: transaction) }
                .frame(minWidth: 460, minHeight: 520)
        }
    }
}
#endif

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
