#if os(macOS)
import BudgetCore
import Charts
import SwiftUI

/// The Mac window: a sidebar of places, people and accounts, and an Overview that shows the
/// whole month at once (key numbers, spending pace, what needs you, and recent activity).
struct MacRootView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var selection: AppSection? = .home

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
        }
        .tint(.brandPink)
        .frame(minWidth: 1080, minHeight: 720)
    }
}

// MARK: Sidebar

extension AppSection {
    /// The Mac sidebar's names, which say a little more than the iPhone's tab titles.
    var macTitle: String {
        switch self {
        case .home: "Overview"
        case .inbox: "Receipts to Check"
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
                ForEach([AppSection.home, .activity, .inbox, .budgets, .plan]) { section in
                    Label(section.macTitle, systemImage: section.macSymbol)
                        .badge(section == .inbox ? store.needsReview.count : 0)
                        .tag(section)
                }
            }
            if store.hasPartner {
                Section("People") {
                    personRow(.me, name: "Me", symbol: "person.fill")
                    personRow(.partner, name: store.couple.partnerName, symbol: "person.fill")
                    personRow(.together, name: "Together", symbol: "person.2.fill")
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
                                        .foregroundStyle(MacPalette.series(index))
                                }
                                Spacer()
                                Text(spent(account.id).money).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(store.accountFilter == account.id ? "Show all accounts" : "Show only this account")
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
        .navigationTitle("Duo Budget")
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
                        .foregroundStyle(view == .partner ? Color.brandPink : view == .me ? Color.brandIndigo : Color.secondary)
                }
                Spacer()
                if store.householdView == view {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
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
            MacKeyNumbers(report: report)
            HStack(alignment: .top, spacing: 16) {
                MacSpendingPace(report: report)
                VStack(spacing: 16) {
                    MacNeedsYou(selection: $selection)
                    MacNextDays()
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

/// A white panel with a title, the building block of the Overview.
struct MacPanel<Content: View, Accessory: View>: View {
    let title: String
    var symbol: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary).imageScale(.small)
                }
                Text(title).font(.headline)
                Spacer()
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

extension MacPanel where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

enum MacPalette {
    static let colors: [Color] = [.brandIndigo, .brandPink, .brandAmber, .green, .blue, .purple, .orange, .teal]
    static func series(_ index: Int) -> Color { colors[index % colors.count] }

    /// One steady colour per category, used for dots in the table.
    static func category(_ name: String) -> Color {
        let index = FinanceCategories.all.firstIndex(of: name) ?? 0
        return [Color.brown, .orange, .green, .pink, .blue, .brandPink, .red, .purple, .indigo, .teal, .mint, .green, .gray, .gray, .gray][index % 15]
    }
}

// MARK: Key numbers

struct MacKeyNumbers: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    let report: MonthlyBudgetReport

    var body: some View {
        let budgeted = report.lines.compactMap(\.limit).reduce(0, +)
        let spentInBudgets = report.lines.filter { $0.limit != nil }.reduce(0) { $0 + $1.spent }
        let safe = store.safeToSpend(contracts: subscriptions.contracts)
        let due = SubscriptionTracker().dueSoon(subscriptions.contracts, from: Date(), days: 30)
        let dueTotal = due.filter { $0.currency == AppSettings.currency }.reduce(0) { $0 + $1.expectedAmount }
        Grid(horizontalSpacing: 12) {
            GridRow {
                if budgeted > 0 {
                    MacKeyNumber(title: "Left to spend", symbol: "banknote", value: (budgeted - spentInBudgets).money,
                                 caption: "of \(budgeted.money) budgeted", tint: .brandIndigo)
                } else {
                    MacKeyNumber(title: "Spent", symbol: "banknote", value: report.spending.money,
                                 caption: "Income \(report.income.money)", tint: .brandIndigo)
                }
                MacKeyNumber(title: "Safe to spend today", symbol: "gauge.with.dots.needle.33percent",
                             value: safe?.today.money ?? "–",
                             caption: safe.map { "\($0.daysLeft) days to go" } ?? "Set a budget to see this",
                             tint: .brandPink)
                if store.hasPartner {
                    let balance = store.coupleBalance
                    MacKeyNumber(title: balance.debtor == .me ? "You owe \(store.couple.partnerName)" : "\(store.couple.partnerName) owes you",
                                 symbol: "arrow.left.arrow.right", value: balance.amountOwed.money,
                                 caption: balance.debtor == nil ? "All square" : "Settle up when it's paid",
                                 tint: .brandPlum)
                } else {
                    MacKeyNumber(title: "Income", symbol: "arrow.down.circle", value: report.income.money,
                                 caption: "this month", tint: .green)
                }
                MacKeyNumber(title: "Bills, next 30 days", symbol: "calendar", value: dueTotal.money,
                             caption: due.count == 1 ? "1 payment" : "\(due.count) payments", tint: .brandAmber)
            }
        }
    }
}

struct MacKeyNumber: View {
    let title: String
    let symbol: String
    let value: String
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title).foregroundStyle(.secondary).lineLimit(1)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint).symbolRenderingMode(.hierarchical)
            }
            .font(.subheadline)
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Spending pace

struct MacSpendingPace: View {
    @EnvironmentObject var store: BudgetStore
    let report: MonthlyBudgetReport

    private struct Point: Identifiable {
        let id = UUID()
        let series: String
        let day: Int
        let amount: Double
    }

    /// Spending so far, day by day, for the month that `month` falls in.
    static func cumulative(_ transactions: [BankTransaction], month: Date, calculator: BudgetCalculator, upTo lastDay: Int? = nil) -> [Decimal] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let days = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let isCurrent = calendar.isDate(month, equalTo: Date(), toGranularity: .month)
        let end = lastDay ?? (isCurrent ? calendar.component(.day, from: Date()) : days)
        let inMonth = transactions.filter { interval.contains($0.date) }
        return (1...max(end, 1)).map { day in
            let cutoff = calendar.date(byAdding: .day, value: day, to: interval.start) ?? interval.end
            return calculator.spendingByCategory(inMonth.filter { $0.date < cutoff }, month: month).values.reduce(0, +)
        }
    }

    var body: some View {
        let calendar = Calendar.current
        let days = calendar.range(of: .day, in: .month, for: store.selectedMonth)?.count ?? 30
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: store.selectedMonth) ?? store.selectedMonth
        let now = Self.cumulative(store.viewTransactions, month: store.selectedMonth, calculator: store.calculator)
        let before = Self.cumulative(store.viewTransactions, month: lastMonth, calculator: store.calculator, upTo: days)
        let budget = report.lines.compactMap(\.limit).reduce(0, +)
        let points = series("This month", now) + series("Last month", before)
        let ahead = budget > 0 && !now.isEmpty ? (budget * Decimal(now.count) / Decimal(days)) - (now.last ?? 0) : nil
        MacPanel(title: "Spending pace", symbol: "chart.line.uptrend.xyaxis") {
            if let ahead {
                Text(ahead >= 0 ? "\(ahead.money) under budget pace" : "\((-ahead).money) over budget pace")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ahead >= 0 ? Color.green : Color.red)
            }
        } content: {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Day", point.day), y: .value("Spent", point.amount), series: .value("Month", point.series))
                        .foregroundStyle(by: .value("Month", point.series))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: point.series == "This month" ? 3 : 2))
                }
                if budget > 0 {
                    LineMark(x: .value("Day", 1), y: .value("Spent", 0.0), series: .value("Month", "Budget"))
                        .foregroundStyle(by: .value("Month", "Budget"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    LineMark(x: .value("Day", days), y: .value("Spent", NSDecimalNumber(decimal: budget).doubleValue), series: .value("Month", "Budget"))
                        .foregroundStyle(by: .value("Month", "Budget"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .chartForegroundStyleScale(["This month": Color.brandIndigo, "Last month": Color.secondary.opacity(0.45), "Budget": Color.brandPink])
            .chartXScale(domain: 1...days)
            .chartYAxis { AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let amount = value.as(Double.self) { Text(amount, format: .currency(code: AppSettings.currency).precision(.fractionLength(0))) } }
            } }
            .chartLegend(position: .top, alignment: .trailing)
            .frame(minHeight: 190, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private func series(_ name: String, _ values: [Decimal]) -> [Point] {
        values.enumerated().map { Point(series: name, day: $0.offset + 1, amount: NSDecimalNumber(decimal: $0.element).doubleValue) }
    }
}

// MARK: Needs you

struct MacNeedsYou: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Binding var selection: AppSection?
    @State private var confirmingSettle = false

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let action: String
        let perform: () -> Void
    }

    private var items: [Item] {
        var items: [Item] = []
        let toCheck = store.needsReview.count
        if toCheck > 0 {
            items.append(Item(id: "check", symbol: "doc.text.magnifyingglass", tint: .brandPink,
                              title: toCheck == 1 ? "1 receipt to check" : "\(toCheck) receipts to check",
                              detail: "Matched to a payment and ready to approve", action: "Review") { selection = .inbox })
        }
        if !store.pendingReceipts.isEmpty {
            let count = store.pendingReceipts.count
            items.append(Item(id: "waiting", symbol: "clock", tint: .secondary,
                              title: count == 1 ? "1 receipt waiting" : "\(count) receipts waiting",
                              detail: "For their payment to reach a statement", action: "Open") { selection = .inbox })
        }
        let rises = subscriptions.priceRises(transactions: store.transactions)
        for contract in subscriptions.contracts {
            guard let rise = rises[contract.id] else { continue }
            let money = { (value: Decimal) in value.formatted(.currency(code: contract.currency)) }
            items.append(Item(id: "rise-\(contract.id)", symbol: "arrow.up.right.circle", tint: .orange,
                              title: "\(contract.vendor) went up \(money(rise.increase))",
                              detail: "\(money(rise.previous)) to \(money(rise.latest)), \(rise.percent.formatted(.percent.precision(.fractionLength(0)))) more",
                              action: "See Bill") { selection = .plan })
        }
        if store.hasPartner, let debtor = store.coupleBalance.debtor {
            let amount = store.coupleBalance.amountOwed.money
            items.append(Item(id: "settle", symbol: "arrow.left.arrow.right.circle", tint: .brandPlum,
                              title: "Settle up with \(store.couple.partnerName)",
                              detail: debtor == .partner ? "\(amount) owed to you" : "You owe \(amount)",
                              action: "Settle") { confirmingSettle = true })
        }
        let attention = store.sharedDocuments.filter(\.needsAttention).count
        if attention > 0 {
            items.append(Item(id: "shared", symbol: "exclamationmark.triangle", tint: .orange,
                              title: attention == 1 ? "1 shared file needs a look" : "\(attention) shared files need a look",
                              detail: "The app wasn't sure what it was", action: "Open") { selection = .inbox })
        }
        return items
    }

    var body: some View {
        MacPanel(title: "Needs you", symbol: "bell") {
            let items = items
            if items.isEmpty {
                Label("All caught up", systemImage: "checkmark.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                        .foregroundStyle(item.tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).fontWeight(.semibold)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(item.action, action: item.perform)
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
                if item.id != items.last?.id { Divider() }
            }
        }
        .confirmationDialog("Mark \(store.coupleBalance.amountOwed.money) as paid back?", isPresented: $confirmingSettle, titleVisibility: .visible) {
            Button("Settled Up") { store.settleUp() }
        } message: {
            Text("Do this once the money has actually been sent. The balance goes back to zero.")
        }
    }
}

struct MacNextDays: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore

    var body: some View {
        let due = SubscriptionTracker().dueSoon(subscriptions.contracts, from: Date(), days: 7)
            .sorted { $0.nextPaymentDueDate < $1.nextPaymentDueDate }
        let rises = subscriptions.priceRises(transactions: store.transactions)
        MacPanel(title: "Next 7 days", symbol: "calendar") {
            if due.isEmpty {
                Text("No bills due this week.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(due) { contract in
                HStack(spacing: 10) {
                    Text(contract.nextPaymentDueDate, format: .dateTime.weekday(.abbreviated))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    Text(contract.vendor).lineLimit(1)
                    if let rise = rises[contract.id] { PriceRiseChip(rise: rise, currency: contract.currency) }
                    Spacer()
                    Text(contract.expectedAmount, format: .currency(code: contract.currency))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
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

    private var rows: [BankTransaction] {
        store.transactions
            .filter { store.accountFilter == nil || $0.accountID == store.accountFilter }
            .filter { !store.hasPartner || store.householdView.includes(store.ledger.owner(of: $0)) }
            .filter { query.isEmpty || $0.merchant.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        MacPanel(title: "Recent activity", symbol: "list.bullet.rectangle") {
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
                    HStack(spacing: 6) {
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
                        Circle().fill(MacPalette.category(transaction.category)).frame(width: 7, height: 7)
                        Text(transaction.category).lineLimit(1)
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
                    ContentUnavailableView(query.isEmpty ? "No transactions yet" : "No results",
                                           systemImage: query.isEmpty ? "list.bullet.rectangle" : "magnifyingglass",
                                           description: Text(query.isEmpty ? "Import a statement or add a receipt." : "Try another shop or category."))
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
