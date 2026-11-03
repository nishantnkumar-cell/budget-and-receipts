import BudgetCore
import Charts
import SwiftUI

// The Overview's panels: key numbers, spending pace, what needs you and the next 7 days.
// The Mac Command centre lays them out side by side; the iPhone Home stacks them on one page.

#if os(iOS)
/// Phone layouts use shorter labels and fixed chart heights.
private let isPhone = true
#else
private let isPhone = false
#endif

/// A white panel with a title, the building block of the Overview.
struct OverviewPanel<Content: View, Accessory: View>: View {
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
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: isPhone ? 18 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: isPhone ? 18 : 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

extension OverviewPanel where Accessory == EmptyView {
    init(title: String, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

enum OverviewPalette {
    static let colors: [Color] = [.brandPink, .brandPartner, .brandTeal, .brandAmber, .green, .blue, .orange, .gray]
    static func series(_ index: Int) -> Color { colors[index % colors.count] }

    /// One steady colour per category, used for dots in the table.
    static func category(_ name: String) -> Color {
        let index = FinanceCategories.all.firstIndex(of: name) ?? 0
        return [Color.brown, .orange, .green, .pink, .blue, .brandPink, .red, .purple, .indigo, .teal, .mint, .green, .gray, .gray, .gray][index % 15]
    }
}

// MARK: Key numbers

struct OverviewKeyNumbers: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    let report: MonthlyBudgetReport

    var body: some View {
        #if os(iOS)
        // Two by two on the phone; net worth, when there is one, gets its own row and opens Net worth.
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                tiles
            }
            if !store.wealthAccounts.isEmpty {
                NavigationLink { NetWorthView() } label: { netWorthTile }
                    .buttonStyle(.plain)
            }
        }
        #else
        Grid(horizontalSpacing: 12) {
            GridRow {
                tiles
                if !store.wealthAccounts.isEmpty { netWorthTile }
            }
        }
        #endif
    }

    @ViewBuilder private var tiles: some View {
        let budgeted = report.lines.compactMap(\.limit).reduce(0, +)
        let spentInBudgets = report.lines.filter { $0.limit != nil }.reduce(0) { $0 + $1.spent }
        let safe = store.safeToSpend(contracts: subscriptions.contracts)
        let pace = SpendingPacePanel.cumulative(store.viewTransactions, month: store.selectedMonth, calculator: store.calculator)
        let due = SubscriptionTracker().dueSoon(store.bills(subscriptions.contracts), from: Date(), days: 30)
        let dueTotal = due.filter { $0.currency == AppSettings.currency }.reduce(0) { $0 + $1.expectedAmount }
        if budgeted > 0 {
            KeyNumberTile(title: "Left to spend", symbol: "banknote", value: (budgeted - spentInBudgets).money,
                          caption: isPhone ? "of \(budgeted.money)" : "of \(budgeted.money) budgeted", tint: .brandIndigo,
                          trend: pace.map { budgeted - $0 })
        } else {
            KeyNumberTile(title: "Spent", symbol: "banknote", value: report.spending.money,
                          caption: "Income \(report.income.money)", tint: .brandIndigo, trend: pace)
        }
        KeyNumberTile(title: isPhone ? "Safe today" : "Safe to spend today", symbol: "gauge.with.dots.needle.33percent",
                      value: safe?.today.money ?? "–",
                      caption: safe.map { "\($0.daysLeft) days to go" }
                         ?? (Calendar.current.isDate(store.selectedMonth, equalTo: Date(), toGranularity: .month) ? (isPhone ? "Set a budget" : "Set a budget to see this") : (isPhone ? "This month only" : "Only for the current month")),
                      tint: .brandPink)
        if store.hasPartner {
            let balance = store.coupleBalance
            KeyNumberTile(title: balance.debtor == .me ? "You owe \(store.couple.partnerName)" : "\(store.couple.partnerName) owes you",
                          symbol: "arrow.left.arrow.right", value: balance.amountOwed.money,
                          caption: balance.debtor == nil ? "All square" : (isPhone ? "Settle when paid" : "Settle up when it's paid"),
                          tint: .brandPlum)
        } else {
            KeyNumberTile(title: "Income", symbol: "arrow.down.circle", value: report.income.money,
                          caption: "this month", tint: .green)
        }
        KeyNumberTile(title: isPhone ? "Bills, 30 days" : "Bills, next 30 days", symbol: "calendar", value: dueTotal.money,
                      caption: subscriptions.contracts.isEmpty ? (isPhone ? "Add them in Plan" : "Add your bills in Plan") : (due.count == 1 ? "1 payment" : "\(due.count) payments"), tint: .brandAmber)
    }

    private var netWorthTile: some View {
        KeyNumberTile(title: "Net worth", symbol: "chart.line.uptrend.xyaxis", value: store.netWorth.wholeMoney,
                      caption: netWorthCaption, tint: .brandTeal)
    }
}

extension OverviewKeyNumbers {
    /// "+£2,180 this month", from the net worth trend.
    var netWorthCaption: String {
        let trend = store.netWorthTrend
        guard trend.count > 1, let last = trend.last?.total else { return "across all accounts" }
        let change = last - trend[trend.count - 2].total
        return "\(change >= 0 ? "+" : "−")\(abs(change).wholeMoney) this month"
    }
}

struct KeyNumberTile: View {
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
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: isPhone ? 18 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: isPhone ? 18 : 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Spending pace

struct SpendingPacePanel: View {
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
        OverviewPanel(title: "Spending pace", symbol: "chart.line.uptrend.xyaxis") {
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
            .frame(minHeight: isPhone ? 170 : 190, maxHeight: isPhone ? 170 : .infinity)
        }
        .frame(maxHeight: isPhone ? nil : .infinity)
    }

    private func series(_ name: String, _ values: [Decimal]) -> [Point] {
        values.enumerated().map { Point(series: name, day: $0.offset + 1, amount: NSDecimalNumber(decimal: $0.element).doubleValue) }
    }
}

// MARK: Needs you

struct NeedsYouPanel: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    /// Opens a place: the Mac selects it in the sidebar, the iPhone pushes it.
    let open: (AppSection) -> Void
    /// The iPhone shows the first few and a "more" row, so Home stays one short page.
    var limit: Int?
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
                              detail: "Matched to a payment and ready to split", action: "Review") { open(.inbox) })
        }
        let uncategorised = store.transactions.filter { $0.category == "Uncategorised" && store.calculator.isInMonth($0.date, store.selectedMonth) }.count
        if uncategorised > 0 {
            items.append(Item(id: "uncategorised", symbol: "tag", tint: .orange,
                              title: uncategorised == 1 ? "1 payment needs a category" : "\(uncategorised) payments need a category",
                              detail: "Set one, or make a rule so it's automatic", action: "Sort") { open(.inbox) })
        }
        let duplicates = store.likelyDuplicates
        if let first = duplicates.first {
            items.append(Item(id: "duplicates", symbol: "doc.on.doc", tint: .orange,
                              title: duplicates.count == 1 ? "Possible duplicate" : "\(duplicates.count) possible duplicates",
                              detail: "\(first.merchant) \(first.amount.money) was added by hand and by a statement", action: "Check") { open(.activity) })
        }
        if !store.pendingReceipts.isEmpty {
            let count = store.pendingReceipts.count
            items.append(Item(id: "waiting", symbol: "clock", tint: .secondary,
                              title: count == 1 ? "1 receipt waiting" : "\(count) receipts waiting",
                              detail: "For their payment to reach a statement", action: "Open") { open(.inbox) })
        }
        let rises = subscriptions.priceRises(transactions: store.transactions)
        for contract in subscriptions.contracts {
            guard let rise = rises[contract.id] else { continue }
            let money = { (value: Decimal) in value.formatted(.currency(code: contract.currency)) }
            items.append(Item(id: "rise-\(contract.id)", symbol: "arrow.up.right.circle", tint: .orange,
                              title: "\(contract.vendor) went up \(money(rise.increase))",
                              detail: "\(money(rise.previous)) to \(money(rise.latest)), \(rise.percent.formatted(.percent.precision(.fractionLength(0)))) more",
                              action: "See Bill") { open(.plan) })
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
                              detail: "\(forecast.billsToCome.money) of bills still to come", action: "See Bills") { open(.plan) })
        }
        let stale = store.staleWealthAccounts.count
        if stale > 0 {
            items.append(Item(id: "stale", symbol: "clock.badge.exclamationmark", tint: .orange,
                              title: stale == 1 ? "1 balance needs updating" : "\(stale) balances need updating",
                              detail: "Pensions, savings or debts not updated for a month", action: "Update") { open(.netWorth) })
        }
        // Last days to cancel in the next two weeks, so a renewal isn't missed.
        let soon = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
        for deadline in ComingUpPlanner().contractDates(subscriptions.contracts, from: Date())
            where deadline.kind == .cancellationDeadline && deadline.date <= soon {
            items.append(Item(id: "cancel-\(deadline.id)", symbol: "exclamationmark.circle", tint: .brandPink,
                              title: "Last day to cancel \(deadline.vendor)",
                              detail: deadline.date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                              action: "See Plan") { open(.plan) })
        }
        let attention = store.sharedDocuments.filter(\.needsAttention).count
        if attention > 0 {
            items.append(Item(id: "shared", symbol: "exclamationmark.triangle", tint: .orange,
                              title: attention == 1 ? "1 shared file needs a look" : "\(attention) shared files need a look",
                              detail: "The app wasn't sure what it was", action: "Open") { open(.inbox) })
        }
        return items
    }

    var body: some View {
        OverviewPanel(title: "Needs you", symbol: "bell") {
            let all = items
            let items = limit.map { Array(all.prefix($0)) } ?? all
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
            if all.count > items.count {
                Divider()
                Button("\(all.count - items.count) more to look at") { open(.inbox) }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .confirmationDialog("Mark \(store.coupleBalance.amountOwed.money) as paid back?", isPresented: $confirmingSettle, titleVisibility: .visible) {
            Button("Settled Up") { store.settleUp() }
        } message: {
            Text("Do this once the money has actually been sent. The balance goes back to zero.")
        }
    }
}

struct NextDaysPanel: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore

    var body: some View {
        let due = SubscriptionTracker().dueSoon(store.bills(subscriptions.contracts), from: Date(), days: 7)
            .sorted { $0.nextPaymentDueDate < $1.nextPaymentDueDate }
        let rises = subscriptions.priceRises(transactions: store.transactions)
        OverviewPanel(title: "Next 7 days", symbol: "calendar") {
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
