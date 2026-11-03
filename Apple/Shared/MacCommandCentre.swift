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
                                        .foregroundStyle(MacPalette.series(index))
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
                MacKeyNumbers(report: report)
            }
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
    static let colors: [Color] = [.brandPink, .brandPartner, .brandTeal, .brandAmber, .green, .blue, .orange, .gray]
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
        let pace = MacSpendingPace.cumulative(store.viewTransactions, month: store.selectedMonth, calculator: store.calculator)
        let due = SubscriptionTracker().dueSoon(subscriptions.contracts, from: Date(), days: 30)
        let dueTotal = due.filter { $0.currency == AppSettings.currency }.reduce(0) { $0 + $1.expectedAmount }
        Grid(horizontalSpacing: 12) {
            GridRow {
                if budgeted > 0 {
                    MacKeyNumber(title: "Left to spend", symbol: "banknote", value: (budgeted - spentInBudgets).money,
                                 caption: "of \(budgeted.money) budgeted", tint: .brandIndigo,
                                 trend: pace.map { budgeted - $0 })
                } else {
                    MacKeyNumber(title: "Spent", symbol: "banknote", value: report.spending.money,
                                 caption: "Income \(report.income.money)", tint: .brandIndigo, trend: pace)
                }
                MacKeyNumber(title: "Safe to spend today", symbol: "gauge.with.dots.needle.33percent",
                             value: safe?.today.money ?? "–",
                             caption: safe.map { "\($0.daysLeft) days to go" }
                                ?? (Calendar.current.isDate(store.selectedMonth, equalTo: Date(), toGranularity: .month) ? "Set a budget to see this" : "Only for the current month"),
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
                             caption: subscriptions.contracts.isEmpty ? "Add your bills in Plan" : (due.count == 1 ? "1 payment" : "\(due.count) payments"), tint: .brandAmber)
                if !store.wealthAccounts.isEmpty {
                    MacKeyNumber(title: "Net worth", symbol: "chart.line.uptrend.xyaxis", value: store.netWorth.wholeMoney,
                                 caption: netWorthCaption, tint: .brandTeal)
                }
            }
        }
    }
}

extension MacKeyNumbers {
    /// "+£2,180 this month", from the net worth trend.
    var netWorthCaption: String {
        let trend = store.netWorthTrend
        guard trend.count > 1, let last = trend.last?.total else { return "across all accounts" }
        let change = last - trend[trend.count - 2].total
        return "\(change >= 0 ? "+" : "−")\(abs(change).wholeMoney) this month"
    }
}

struct MacKeyNumber: View {
    let title: String
    let symbol: String
    let value: String
    let caption: String
    let tint: Color
    /// A small trend for the month so far, drawn beside the caption.
    var trend: [Decimal] = []

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
            HStack(spacing: 8) {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if trend.count > 1 {
                    Chart(Array(trend.enumerated()), id: \.offset) { point in
                        LineMark(x: .value("Day", point.offset), y: .value("Amount", NSDecimalNumber(decimal: point.element).doubleValue))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(tint)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(width: 56, height: 16)
                    .accessibilityHidden(true)
                }
            }
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

    static func ordinal(_ day: Int) -> String {
        let suffix = (11...13).contains(day % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][day % 10] ?? "th"
        return "\(day)\(suffix)"
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
                if let last = now.last {
                    PointMark(x: .value("Day", now.count), y: .value("Spent", NSDecimalNumber(decimal: last).doubleValue))
                        .foregroundStyle(Color.brandPink)
                        .annotation(position: .topLeading, spacing: 6) {
                            Text("\(last.wholeMoney) by the \(Self.ordinal(now.count))")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cardBackground.opacity(0.9), in: Capsule())
                        }
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
            .chartForegroundStyleScale(["This month": Color.brandPink, "Last month": Color.secondary.opacity(0.45), "Budget": Color.brandAmber])
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
        let toApprove = store.receiptsToApprove.count
        if toApprove > 0 {
            items.append(Item(id: "check", symbol: "doc.text.magnifyingglass", tint: .brandPink,
                              title: toApprove == 1 ? "1 receipt to approve" : "\(toApprove) receipts to approve",
                              detail: "Matched to a payment and ready to split", action: "Review") { selection = .inbox })
        }
        let uncategorised = store.transactions.filter { $0.category == "Uncategorised" && store.calculator.isInMonth($0.date, store.selectedMonth) }.count
        if uncategorised > 0 {
            items.append(Item(id: "uncategorised", symbol: "tag", tint: .orange,
                              title: uncategorised == 1 ? "1 payment needs a category" : "\(uncategorised) payments need a category",
                              detail: "Set one, or make a rule so it's automatic", action: "Sort") { selection = .inbox })
        }
        let duplicates = store.likelyDuplicates
        if let first = duplicates.first {
            items.append(Item(id: "duplicates", symbol: "doc.on.doc", tint: .orange,
                              title: duplicates.count == 1 ? "Possible duplicate" : "\(duplicates.count) possible duplicates",
                              detail: "\(first.merchant) \(first.amount.money) was added by hand and by a statement", action: "Check") { selection = .activity })
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
        if let forecast = store.balanceForecast(contracts: subscriptions.contracts), forecast.goesOverdrawn {
            items.append(Item(id: "overdrawn", symbol: "exclamationmark.triangle", tint: .red,
                              title: "Heading for \(forecast.endOfMonth.money) by month end",
                              detail: "\(forecast.billsToCome.money) of bills still to come", action: "See Bills") { selection = .plan })
        }
        let stale = store.staleWealthAccounts.count
        if stale > 0 {
            items.append(Item(id: "stale", symbol: "clock.badge.exclamationmark", tint: .orange,
                              title: stale == 1 ? "1 balance needs updating" : "\(stale) balances need updating",
                              detail: "Pensions, savings or debts not updated for a month", action: "Update") { selection = .netWorth })
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
        MacPanel(title: "\(store.selectedMonth.formatted(.dateTime.month(.wide))) activity", symbol: "list.bullet.rectangle") {
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
                        Circle().fill(MacPalette.category(transaction.category)).frame(width: 7, height: 7)
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
