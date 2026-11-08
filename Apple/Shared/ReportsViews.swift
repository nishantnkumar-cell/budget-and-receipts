import BudgetCore
import Charts
import SwiftUI
import UniformTypeIdentifiers

// Reports: cash flow, categories (down to sub-categories and shops), top shops and a year in
// review. Every view reads store.viewTransactions, so it follows the Me / Partner / Together
// switch and the account filter like the rest of the app.

enum ReportKind: String, CaseIterable, Identifiable {
    case cashFlow = "Cash flow"
    case categories = "Categories"
    case shops = "Shops"
    case year = "Year"
    case netWorth = "Net worth"

    var id: String { rawValue }
}

/// How far back the cash flow, category and shop reports look.
enum ReportRange: Int, CaseIterable, Identifiable {
    case three = 3, six = 6, twelve = 12

    var id: Int { rawValue }
    var label: String { "\(rawValue) months" }
}

extension BudgetStore {
    /// The budget months a report covers, ending at the month being viewed.
    func reportInterval(months: Int) -> DateInterval {
        let first = Reports.months(endingAt: selectedMonth, count: months, calculator: calculator).first ?? selectedMonth
        return DateInterval(start: calculator.monthInterval(for: first).start, end: calculator.monthInterval(for: selectedMonth).end)
    }

    func cashFlow(months: Int) -> CashFlowReport {
        CashFlowReport.make(viewTransactions, endingAt: selectedMonth, count: months, calculator: calculator)
    }

    func categoryTrends(months: Int) -> CategoryTrendsReport {
        CategoryTrendsReport.make(viewTransactions, endingAt: selectedMonth, count: months, calculator: calculator)
    }

    func topShops(months: Int, category: String? = nil, subcategory: String? = nil, limit: Int? = nil) -> [ShopSpending] {
        let interval = reportInterval(months: months)
        return TopShops.make(viewTransactions, from: interval.start, to: interval.end, category: category, subcategory: subcategory, limit: limit, calculator: calculator)
    }

    func yearInReview(_ year: Int) -> YearInReview {
        YearInReview.make(viewTransactions, year: year, calculator: calculator)
    }

    /// Net worth over the last few months, for the Me / Partner / Together switch.
    func netWorthReport(months: Int) -> NetWorthReport {
        NetWorthReport.make(wealthAccounts, view: householdView, ledger: hasPartner ? ledger : nil, months: months)
    }

    /// Spending by whose money it was. Only for Together with a partner: the Me and Partner
    /// views already show one person's share.
    func ownerSpending(in interval: DateInterval) -> OwnerSpending? {
        guard hasPartner, householdView == .together else { return nil }
        return OwnerSpending.make(viewTransactions, from: interval.start, to: interval.end, ledger: ledger, calculator: calculator)
    }

    func ownerSpending(months: Int) -> OwnerSpending? { ownerSpending(in: reportInterval(months: months)) }

    func ownerSpending(year: Int) -> OwnerSpending? {
        let months = Reports.months(endingAt: calculator.calendar.date(from: DateComponents(year: year, month: 12, day: 15)) ?? Date(), count: 12, calculator: calculator)
        guard let first = months.first, let last = months.last else { return nil }
        return ownerSpending(in: DateInterval(start: calculator.monthInterval(for: first).start, end: calculator.monthInterval(for: last).end))
    }

    /// The payments at one shop in a date range, newest first.
    func payments(at shop: ShopSpending, in interval: DateInterval) -> [BankTransaction] {
        viewTransactions
            .filter { interval.contains($0.date) && (Categoriser.merchantKey($0.merchant).isEmpty ? $0.merchant.uppercased() : Categoriser.merchantKey($0.merchant)) == shop.key }
            .sorted { $0.date > $1.date }
    }
}

struct ReportsView: View {
    @EnvironmentObject var store: BudgetStore
    @AppStorage("reports.kind") private var kind = ReportKind.cashFlow
    @AppStorage("reports.range") private var range = ReportRange.twelve
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var exportingPDF = false
    @State private var exportingCSV = false
    @State private var exportError: String?

    private var years: [Int] { YearInReview.years(in: store.viewTransactions) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                HouseholdSwitcher()
                Picker("Report", selection: $kind) {
                    ForEach(ReportKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                controls
                if kind == .netWorth {
                    NetWorthReportSection(report: store.netWorthReport(months: range.rawValue))
                } else if store.viewTransactions.isEmpty {
                    ContentUnavailableView("No payments yet", systemImage: "chart.bar.xaxis",
                                           description: Text("Import a statement and your reports appear here."))
                        .card()
                } else {
                    switch kind {
                    case .cashFlow: CashFlowSection(report: store.cashFlow(months: range.rawValue), owners: store.ownerSpending(months: range.rawValue))
                    case .categories: CategoryTrendsSection(report: store.categoryTrends(months: range.rawValue), months: range.rawValue)
                    case .shops: TopShopsSection(shops: store.topShops(months: range.rawValue), months: range.rawValue)
                    case .year: YearInReviewSection(review: store.yearInReview(year), owners: store.ownerSpending(year: year))
                    case .netWorth: EmptyView()
                    }
                }
            }
            .padding()
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .appBackground()
        .navigationTitle("Reports")
        .onAppear { if let latest = years.first, !years.contains(year) { year = latest } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { AccountFilterMenu() }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { exportingPDF = true } label: { Label("Export as PDF", systemImage: "doc.richtext") }
                    Button { exportingCSV = true } label: { Label("Export as CSV", systemImage: "tablecells") }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Export report")
                .disabled(kind == .netWorth ? store.wealthAccounts.isEmpty : store.viewTransactions.isEmpty)
            }
        }
        .fileExporter(isPresented: $exportingPDF, document: ExportDocument(data: exportPDF(), type: .pdf), contentType: .pdf,
                      defaultFilename: "\(exportName).pdf") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportingCSV, document: ExportDocument(data: Data(exportCSV().utf8), type: .commaSeparatedText), contentType: .commaSeparatedText,
                      defaultFilename: "\(exportName).csv") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Couldn't export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    @ViewBuilder private var controls: some View {
        HStack {
            if kind == .year {
                Picker("Year", selection: $year) {
                    ForEach(years.isEmpty ? [year] : years, id: \.self) { Text(String($0)).tag($0) }
                }
                .fixedSize()
            } else {
                Picker("Range", selection: $range) {
                    ForEach(ReportRange.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                if kind != .netWorth {
                    Spacer()
                    MonthSwitcher()
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Export

    private var exportName: String {
        let who = store.hasPartner ? " (\(store.householdView.label(partnerName: store.couple.partnerName, myName: store.couple.ownerName)))" : ""
        switch kind {
        case .year: return "Year in review \(year)\(who)"
        case .netWorth: return "Net worth \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))\(who)"
        default: return "\(kind.rawValue) to \(store.selectedMonth.formatted(.dateTime.year().month(.twoDigits)))\(who)"
        }
    }

    private func exportCSV() -> String {
        switch kind {
        case .cashFlow: store.cashFlow(months: range.rawValue).csv()
        case .categories: store.categoryTrends(months: range.rawValue).csv()
        case .shops: TopShops.csv(store.topShops(months: range.rawValue))
        case .year: store.yearInReview(year).cashFlow.csv()
        case .netWorth: store.netWorthReport(months: range.rawValue).csv()
        }
    }

    private func exportPDF() -> Data {
        guard exportingPDF else { return Data() }
        let page: AnyView = switch kind {
        case .cashFlow: AnyView(CashFlowSection(report: store.cashFlow(months: range.rawValue), owners: store.ownerSpending(months: range.rawValue), printing: true))
        case .categories: AnyView(CategoryTrendsSection(report: store.categoryTrends(months: range.rawValue), months: range.rawValue, printing: true))
        case .shops: AnyView(TopShopsSection(shops: store.topShops(months: range.rawValue, limit: 25), months: range.rawValue, printing: true))
        case .year: AnyView(YearInReviewSection(review: store.yearInReview(year), owners: store.ownerSpending(year: year), printing: true))
        case .netWorth: AnyView(NetWorthReportSection(report: store.netWorthReport(months: range.rawValue), printing: true))
        }
        return ReportPDF.render(title: exportName, page.environmentObject(store))
    }
}

// MARK: Cash flow

struct CashFlowSection: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let report: CashFlowReport
    var owners: OwnerSpending? = nil
    var printing = false

    private var compact: Bool { sizeClass == .compact }

    var body: some View {
        VStack(spacing: Theme.spacing) {
            HStack(spacing: 10) {
                SummaryTile(title: "Money in", amount: report.totalIncome, tint: .green)
                SummaryTile(title: "Spent", amount: report.totalSpending)
                SummaryTile(title: report.net >= 0 ? "Kept" : "Overspent", amount: report.net, tint: report.net >= 0 ? .green : .brandPink)
            }
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "In and out") {
                    if let rate = report.savingsRate {
                        Text("Kept \(rate.formatted(.percent.precision(.fractionLength(0)))) of income").foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(report.months) { flow in
                        BarMark(x: .value("Month", flow.month, unit: .month), y: .value("Amount", flow.income.double))
                            .foregroundStyle(by: .value("Kind", "Money in"))
                            .position(by: .value("Kind", "Money in"))
                        BarMark(x: .value("Month", flow.month, unit: .month), y: .value("Amount", flow.spending.double))
                            .foregroundStyle(by: .value("Kind", "Spent"))
                            .position(by: .value("Kind", "Spent"))
                    }
                    RuleMark(y: .value("Average", report.averageSpending.double))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Average spend \(report.averageSpending.wholeMoney)").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartForegroundStyleScale(["Money in": Color.green.opacity(0.75), "Spent": Color.brandPink])
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
                .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { Text(Decimal(amount).wholeMoney) } } } }
                .frame(height: 220)
            }
            .card()
            if let owners, owners.total > 0 { WhoSpentCard(spending: owners) }
            VStack(spacing: 0) {
                ForEach(report.months.reversed()) { flow in
                    HStack {
                        Text(compact ? flow.month.formatted(.dateTime.month(.abbreviated).year(.twoDigits)) : flow.month.formatted(.dateTime.month(.wide).year()))
                        Spacer()
                        Text(compact ? flow.income.wholeMoney : flow.income.money).foregroundStyle(.green).frame(minWidth: compact ? 64 : 90, alignment: .trailing)
                        Text(compact ? flow.spending.wholeMoney : flow.spending.money).frame(minWidth: compact ? 64 : 90, alignment: .trailing)
                        Text(compact ? flow.net.wholeMoney : flow.net.money).fontWeight(.semibold).foregroundStyle(flow.net >= 0 ? Color.primary : Color.brandPink)
                            .frame(minWidth: compact ? 64 : 90, alignment: .trailing)
                    }
                    .monospacedDigit()
                    .font(.subheadline)
                    .padding(.vertical, 8)
                    if flow.id != report.months.first?.id { Divider() }
                }
            }
            .card(padding: 12)
        }
    }
}

// MARK: Categories

struct CategoryTrendsSection: View {
    @EnvironmentObject var store: BudgetStore
    let report: CategoryTrendsReport
    let months: Int
    var printing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            if report.categories.isEmpty {
                Text("No spending in these months.").foregroundStyle(.secondary).card()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader("Each month by category")
                    Chart {
                        ForEach(report.categories.prefix(6)) { trend in
                            ForEach(Array(zip(report.months, trend.category.monthly)), id: \.0) { month, amount in
                                BarMark(x: .value("Month", month, unit: .month), y: .value("Spent", amount.double))
                                    .foregroundStyle(by: .value("Category", trend.category.name))
                            }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                    .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { Text(Decimal(amount).wholeMoney) } } } }
                    .frame(height: 220)
                    if report.categories.count > 6 {
                        Text("The six biggest categories are shown.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .card()
                VStack(spacing: 0) {
                    ForEach(report.categories) { trend in
                        let shops = topShops(for: trend)
                        if printing {
                            TrendRow(trend: trend.category, months: report.months, shops: shops)
                            ForEach(trend.subcategories) { TrendRow(trend: $0, months: report.months, indent: true) }
                        } else {
                            NavigationLink { CategoryReportDetail(trend: trend, months: report.months, range: months) } label: {
                                TrendRow(trend: trend.category, months: report.months, shops: shops, showsChevron: true)
                            }
                            .buttonStyle(.plain)
                        }
                        if trend.id != report.categories.last?.id { Divider() }
                    }
                }
                .card(padding: 12)
            }
        }
    }

    /// The three shops most of a category's money went to, for its row.
    private func topShops(for trend: CategoryTrend) -> [ShopSpending] {
        store.topShops(months: months, category: trend.category.name, limit: 3)
    }
}

/// A category or sub-category: its total, a small trend line and how the latest month compares.
struct TrendRow: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let trend: SpendingTrend
    let months: [Date]
    /// The biggest shops in it, named under the monthly average.
    var shops: [ShopSpending] = []
    var indent = false
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            if !indent { CategoryIcon(category: trend.name) }
            VStack(alignment: .leading, spacing: 2) {
                Text(trend.name).font(indent ? .subheadline : .body.weight(.semibold))
                Text("\(trend.average.wholeMoney) a month").font(.caption).foregroundStyle(.secondary)
                if !shops.isEmpty {
                    Text(shops.map { "\($0.name) \($0.total.wholeMoney)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, indent ? 44 : 0)
            Spacer()
            if sizeClass != .compact { Sparkline(values: trend.monthly).frame(width: 70, height: 24) }
            ChangeBadge(change: trend.latestChange)
            Text(trend.total.wholeMoney).monospacedDigit().fontWeight(.semibold).frame(minWidth: 72, alignment: .trailing)
            if showsChevron { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The latest month against the average of the ones before: up in pink, down in green.
struct ChangeBadge: View {
    let change: Double?

    var body: some View {
        if let change, abs(change) >= 0.05 {
            Label(abs(change).formatted(.percent.precision(.fractionLength(0))), systemImage: change > 0 ? "arrow.up.right" : "arrow.down.right")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(change > 0 ? Color.brandPink : Color.green)
                .frame(minWidth: 56, alignment: .trailing)
                .help("Latest month against the average of the months before")
        } else {
            Color.clear.frame(width: 56, height: 1)
        }
    }
}

struct Sparkline: View {
    let values: [Decimal]

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("Month", index), y: .value("Spent", value.double))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.brandPlum)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .accessibilityHidden(true)
    }
}

struct CategoryIcon: View {
    let category: String
    var size: CGFloat = 32

    var body: some View {
        IconBadge(systemImage: Self.symbol(for: category), tint: Self.tint(for: category), size: size)
    }

    /// The icon chosen in Settings › Categories.
    static func symbol(for category: String) -> String {
        FinanceCategories.catalog.definition(named: category)?.symbol ?? "questionmark.circle"
    }

    /// The colour chosen in Settings › Categories.
    static func tint(for category: String) -> Color {
        FinanceCategories.catalog.definition(named: category)?.color.swatch ?? .gray
    }
}

/// One category over the report's months: its sub-categories and the shops the money went to.
struct CategoryReportDetail: View {
    @EnvironmentObject var store: BudgetStore
    let trend: CategoryTrend
    let months: [Date]
    let range: Int
    @State private var subcategory: String?

    var body: some View {
        let shops = store.topShops(months: range, category: trend.category.name, subcategory: subcategory)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(spacing: 10) {
                    SummaryTile(title: "Total", amount: trend.category.total)
                    SummaryTile(title: "A month", amount: Reports.rounded(trend.category.average))
                    SummaryTile(title: months.last?.formatted(.dateTime.month(.wide)) ?? "Latest", amount: trend.category.monthly.last ?? 0)
                }
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader("Each month")
                    Chart {
                        ForEach(trend.subcategories.isEmpty ? [trend.category] : trend.subcategories) { sub in
                            ForEach(Array(zip(months, sub.monthly)), id: \.0) { month, amount in
                                BarMark(x: .value("Month", month, unit: .month), y: .value("Spent", amount.double))
                                    .foregroundStyle(by: .value("Sub-category", sub.name))
                                    .opacity(subcategory == nil || subcategory == sub.name ? 1 : 0.25)
                            }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                    .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { Text(Decimal(amount).wholeMoney) } } } }
                    .frame(height: 200)
                }
                .card()
                if !trend.subcategories.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        CardHeader("Sub-categories").padding(.bottom, 4)
                        ForEach(trend.subcategories) { sub in
                            Button { subcategory = subcategory == sub.name ? nil : sub.name } label: {
                                HStack {
                                    Image(systemName: subcategory == sub.name ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(subcategory == sub.name ? Color.brandPink : Color.secondary)
                                    TrendRow(trend: sub, months: months, indent: true).padding(.leading, -44)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows only this sub-category's shops")
                        }
                    }
                    .card(padding: 12)
                }
                VStack(alignment: .leading, spacing: 0) {
                    CardHeader(subcategory.map { "Shops for \($0)" } ?? "Shops").padding(.bottom, 4)
                    ShopList(shops: shops, interval: store.reportInterval(months: range))
                }
                .card(padding: 12)
            }
            .padding()
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .appBackground()
        .navigationTitle(trend.category.name)
    }
}

// MARK: Shops

struct TopShopsSection: View {
    @EnvironmentObject var store: BudgetStore
    let shops: [ShopSpending]
    let months: Int
    var printing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            if shops.isEmpty {
                Text("No spending in these months.").foregroundStyle(.secondary).card()
            } else {
                let top = Array(shops.prefix(10))
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: "Top 10 shops") {
                        Text("\(shops.count) shops in all").foregroundStyle(.secondary)
                    }
                    let largest = top.first?.total.double ?? 1
                    ForEach(top) { shop in
                        HStack(spacing: 10) {
                            Text(shop.name).font(.subheadline).lineLimit(1).frame(width: 110, alignment: .leading)
                            GeometryReader { proxy in
                                Capsule().fill(Color.brandPlum.gradient)
                                    .frame(width: max(4, proxy.size.width * shop.total.double / max(largest, 1)))
                            }
                            .frame(height: 10)
                            Text(shop.total.wholeMoney).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .card()
                VStack(spacing: 0) {
                    ShopList(shops: shops, interval: store.reportInterval(months: months), printing: printing)
                }
                .card(padding: 12)
            }
        }
    }
}

struct ShopList: View {
    let shops: [ShopSpending]
    let interval: DateInterval
    var printing = false

    var body: some View {
        if shops.isEmpty {
            Text("Nothing spent here in these months.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 8)
        }
        ForEach(shops) { shop in
            if printing {
                ShopRow(shop: shop)
            } else {
                NavigationLink { ShopPaymentsView(shop: shop, interval: interval) } label: { ShopRow(shop: shop, showsChevron: true) }
                    .buttonStyle(.plain)
            }
            if shop.id != shops.last?.id { Divider() }
        }
    }
}

struct ShopRow: View {
    let shop: ShopSpending
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: shop.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(shop.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(shop.visits == 1 ? "1 visit · \(shop.category)" : "\(shop.visits) visits · \(shop.averageVisit.wholeMoney) each · \(shop.category)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(shop.total.money).monospacedDigit().fontWeight(.semibold)
            if showsChevron { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ShopPaymentsView: View {
    @EnvironmentObject var store: BudgetStore
    let shop: ShopSpending
    let interval: DateInterval

    var body: some View {
        List {
            Section {
                LabeledContent("Spent") { Text(shop.total.money).monospacedDigit().fontWeight(.semibold) }
                LabeledContent("Visits", value: "\(shop.visits)")
                LabeledContent("Last visit", value: shop.lastVisit.formatted(date: .abbreviated, time: .omitted))
            }
            Section("Payments") {
                ForEach(store.payments(at: shop, in: interval)) { TransactionRow(transaction: $0) }
            }
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationTitle(shop.name)
    }
}

// MARK: Year in review

struct YearInReviewSection: View {
    let review: YearInReview
    var owners: OwnerSpending? = nil
    var printing = false

    var body: some View {
        let flow = review.cashFlow
        VStack(alignment: .leading, spacing: Theme.spacing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(String(review.year)) in review").font(.title2.bold())
                Text("You spent \(flow.totalSpending.wholeMoney) across \(review.payments) payments.")
                    .font(.title3)
                if review.previousYearSpending > 0 {
                    let change = review.spendingChange
                    Label(change <= 0 ? "\((-change).wholeMoney) less than \(String(review.year - 1))" : "\(change.wholeMoney) more than \(String(review.year - 1))",
                          systemImage: change <= 0 ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill")
                        .foregroundStyle(change <= 0 ? Color.green : Color.brandPink)
                }
            }
            .card()
            HStack(spacing: 10) {
                SummaryTile(title: "Money in", amount: flow.totalIncome, tint: .green)
                SummaryTile(title: "Spent", amount: flow.totalSpending)
                SummaryTile(title: flow.net >= 0 ? "Kept" : "Overspent", amount: flow.net, tint: flow.net >= 0 ? .green : .brandPink)
            }
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("Spending each month")
                Chart(flow.months) { month in
                    BarMark(x: .value("Month", month.month, unit: .month), y: .value("Spent", month.spending.double))
                        .foregroundStyle(month.id == review.busiestMonth?.id ? Color.brandPink : Color.brandPlum.opacity(0.6))
                }
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
                .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { Text(Decimal(amount).wholeMoney) } } } }
                .frame(height: 180)
                HStack {
                    if let busiest = review.busiestMonth {
                        Label("Busiest: \(busiest.month.formatted(.dateTime.month(.wide))), \(busiest.spending.wholeMoney)", systemImage: "flame")
                    }
                    Spacer()
                    if let quietest = review.quietestMonth, quietest.id != review.busiestMonth?.id {
                        Label("Quietest: \(quietest.month.formatted(.dateTime.month(.wide))), \(quietest.spending.wholeMoney)", systemImage: "leaf")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .card()
            if let owners, owners.total > 0 { WhoSpentCard(spending: owners) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.spacing) { categories; shops }
                VStack(spacing: Theme.spacing) { categories; shops }
            }
            if review.mostVisited != nil || review.biggestPurchase != nil {
                VStack(alignment: .leading, spacing: 10) {
                    if let favourite = review.mostVisited {
                        Label {
                            Text("Most visited: **\(favourite.name)**, \(favourite.visits) times")
                        } icon: { Image(systemName: "star") }
                    }
                    if let biggest = review.biggestPurchase {
                        Label {
                            Text("Biggest purchase: **\((-biggest.amount).money)** at \(Reports.shopName(biggest.merchant)) on \(biggest.date.formatted(.dateTime.day().month(.wide)))")
                        } icon: { Image(systemName: "trophy") }
                    }
                }
                .card()
            }
        }
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader("Top categories")
            ForEach(review.topCategories, id: \.category) { row in
                HStack {
                    CategoryIcon(category: row.category)
                    Text(row.category)
                    Spacer()
                    Text(row.amount.wholeMoney).monospacedDigit().fontWeight(.semibold)
                }
            }
        }
        .card()
    }

    private var shops: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader("Top shops")
            ForEach(review.topShops) { shop in
                HStack {
                    CategoryIcon(category: shop.category)
                    Text(shop.name).lineLimit(1)
                    Spacer()
                    Text(shop.total.wholeMoney).monospacedDigit().fontWeight(.semibold)
                }
            }
        }
        .card()
    }
}

// MARK: PDF

extension Decimal {
    var double: Double { NSDecimalNumber(decimal: self).doubleValue }
}

/// An A4-wide PDF of a report, as tall as the report needs.
@MainActor
enum ReportPDF {
    static func render(title: String, _ content: some View) -> Data {
        let page = VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title.bold())
            content
            Text("Made with Duo Budget on \(Date().formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 595)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(width: 595, height: nil)
        let data = NSMutableData()
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return data as Data
    }
}

// MARK: Who spent it

extension MoneyOwner {
    /// Violet for mine, magenta for the partner's and teal for shared, as everywhere else.
    var tint: Color {
        switch self {
        case .mine: .brandPlum
        case .partner: .brandPartner
        case .shared: .brandTeal
        }
    }

    var systemImage: String {
        switch self {
        case .mine: "person.fill"
        case .partner: "person"
        case .shared: "person.2.fill"
        }
    }
}

/// Spending split into mine, the partner's and shared: one bar, then a line for each.
struct WhoSpentCard: View {
    @EnvironmentObject var store: BudgetStore
    let spending: OwnerSpending

    private var owners: [MoneyOwner] { MoneyOwner.allCases.filter { spending[$0] != 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader("Whose spending")
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(owners, id: \.self) { owner in
                        Rectangle().fill(owner.tint)
                            .frame(width: max(2, (proxy.size.width - CGFloat(owners.count - 1) * 2) * max(spending.fraction(owner), 0)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            ForEach(owners, id: \.self) { owner in
                HStack(spacing: 10) {
                    Image(systemName: owner.systemImage).foregroundStyle(owner.tint).frame(width: 20)
                    Text(owner.label(partnerName: store.couple.partnerName))
                    Spacer()
                    Text(spending.fraction(owner).formatted(.percent.precision(.fractionLength(0)))).foregroundStyle(.secondary)
                    Text(spending[owner].wholeMoney).monospacedDigit().fontWeight(.semibold).frame(minWidth: 80, alignment: .trailing)
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

// MARK: Net worth

/// Net worth over time. Pensions and property get their own tiles and lines, since neither
/// can be spent, and the total without them is shown next to the full figure.
struct NetWorthReportSection: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let report: NetWorthReport
    var printing = false

    private static let withoutLabel = "Without pensions and property"

    var body: some View {
        if report.groups.isEmpty {
            ContentUnavailableView {
                Label("No accounts yet", systemImage: "building.columns")
            } description: {
                Text("Add savings, pensions, your home and mortgage in Net worth, and this report shows how they change.")
            }
            .card()
        } else {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                tiles
                if report.points.count > 1 { chart }
                breakdown
            }
        }
    }

    @ViewBuilder private var tiles: some View {
        let first = HStack(spacing: 10) {
            SummaryTile(title: "Net worth", amount: report.total)
            SummaryTile(title: "Without pensions and property", amount: report.excludingPensionsAndProperty)
        }
        let second = HStack(spacing: 10) {
            SummaryTile(title: "Pensions", amount: report.pensions)
            SummaryTile(title: "Home equity", amount: report.homeEquity)
        }
        if sizeClass == .compact && !printing {
            VStack(spacing: 10) { first; second }
        } else {
            HStack(spacing: 10) { first; second }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Over time") {
                if let change = report.change {
                    Label(change >= 0 ? "Up \(change.wholeMoney)" : "Down \((-change).wholeMoney)",
                          systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(change >= 0 ? Color.green : Color.brandPink)
                }
            }
            Chart {
                ForEach(report.points) { point in
                    LineMark(x: .value("Month", point.month, unit: .month), y: .value("Amount", point.total.double))
                        .foregroundStyle(by: .value("Line", "Net worth"))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Month", point.month, unit: .month),
                             y: .value("Amount", (point.total - point.amount(.pensions) - point.amount(.property) - point.amount(.mortgage)).double))
                        .foregroundStyle(by: .value("Line", Self.withoutLabel))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Month", point.month, unit: .month), y: .value("Amount", point.amount(.pensions).double))
                        .foregroundStyle(by: .value("Line", "Pensions"))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Month", point.month, unit: .month), y: .value("Amount", (point.amount(.property) + point.amount(.mortgage)).double))
                        .foregroundStyle(by: .value("Line", "Home equity"))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Net worth": Color.brandPink, Self.withoutLabel: Color.brandTeal,
                                        "Pensions": Color.brandPartner, "Home equity": Color.secondary])
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(amount, format: .currency(code: AppSettings.currency).notation(.compactName)) } }
                }
            }
            .frame(height: 220)
        }
        .card()
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("What it's made of").padding(.bottom, 4)
            ForEach(report.groups, id: \.group) { row in
                line(row.group.title, systemImage: Self.symbol(for: row.group), amount: row.amount)
                Divider()
            }
            if report.property != 0 || report.mortgage != 0 {
                line("Home equity (property less mortgage)", systemImage: "house.fill", amount: report.homeEquity, bold: true)
                Divider()
            }
            line(Self.withoutLabel, systemImage: "banknote", amount: report.excludingPensionsAndProperty, bold: true)
            Divider()
            line("Net worth", systemImage: "sum", amount: report.total, bold: true)
        }
        .card(padding: 12)
    }

    private func line(_ title: String, systemImage: String, amount: Decimal, bold: Bool = false) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: systemImage, size: 28)
            Text(title).fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(amount.money).monospacedDigit().fontWeight(bold ? .semibold : .regular)
                .foregroundStyle(amount < 0 ? Color.brandPink : Color.primary)
        }
        .font(.subheadline)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    static func symbol(for group: WealthAccount.Group) -> String {
        switch group {
        case .cash: "banknote"
        case .investments: "chart.line.uptrend.xyaxis"
        case .pensions: "beach.umbrella"
        case .property: "house"
        case .mortgage: "key.horizontal"
        case .otherDebts: "creditcard"
        case .other: "square.stack.3d.up"
        }
    }
}
