import Foundation

// The Reports area: cash flow, category trends, top shops and a year in review. Every report
// takes the transactions already narrowed to one account and one side of the household, so the
// Me / Partner / Together switch and the account filter work without anything special here.

/// Income and spending for one budget month.
public struct MonthFlow: Identifiable, Hashable, Sendable {
    public var id: Date { month }
    public let month: Date
    public let income: Decimal
    public let spending: Decimal
    public var net: Decimal { income - spending }
}

/// Money in and out, month by month.
public struct CashFlowReport: Hashable, Sendable {
    public let months: [MonthFlow]

    public var totalIncome: Decimal { months.reduce(0) { $0 + $1.income } }
    public var totalSpending: Decimal { months.reduce(0) { $0 + $1.spending } }
    public var net: Decimal { totalIncome - totalSpending }
    /// The share of income kept, from 0 to 1. Nil when there was no income.
    public var savingsRate: Double? {
        guard totalIncome > 0 else { return nil }
        return NSDecimalNumber(decimal: net / totalIncome).doubleValue
    }
    public var averageSpending: Decimal {
        let active = months.filter { $0.income != 0 || $0.spending != 0 }
        return active.isEmpty ? 0 : totalSpending / Decimal(active.count)
    }

    /// The `count` months up to and including `month`, oldest first. Months before the first
    /// payment are left out, so a new user doesn't see a year of empty bars.
    public static func make(_ transactions: [BankTransaction], endingAt month: Date, count: Int = 12, calculator: BudgetCalculator = BudgetCalculator()) -> CashFlowReport {
        let months = Reports.months(endingAt: month, count: count, calculator: calculator)
        let flows = months.map { month in
            MonthFlow(month: month,
                      income: calculator.income(transactions, month: month),
                      spending: calculator.spendingByCategory(transactions, month: month).values.reduce(0, +))
        }
        let firstActive = flows.firstIndex { $0.income != 0 || $0.spending != 0 } ?? flows.endIndex
        return CashFlowReport(months: Array(flows[firstActive...]))
    }
}

/// One category or sub-category's spending, month by month.
public struct SpendingTrend: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    /// Spending in each month of the report, oldest first.
    public let monthly: [Decimal]
    public var total: Decimal { monthly.reduce(0, +) }
    public var average: Decimal { monthly.isEmpty ? 0 : total / Decimal(monthly.count) }
    /// The latest month against the average of the months before it, from -1 up. Nil without history.
    public var latestChange: Double? {
        guard monthly.count > 1, let latest = monthly.last else { return nil }
        let earlier = monthly.dropLast()
        let average = earlier.reduce(0, +) / Decimal(earlier.count)
        guard average > 0 else { return nil }
        return NSDecimalNumber(decimal: (latest - average) / average).doubleValue
    }
}

/// A category's trend with its sub-categories under it.
public struct CategoryTrend: Identifiable, Hashable, Sendable {
    public var id: String { category.name }
    public let category: SpendingTrend
    /// Sub-categories, biggest first. Spending with no sub-category is "Other" when the
    /// category has some that are named.
    public let subcategories: [SpendingTrend]
}

/// Spending per category over a run of months, for spotting what's growing.
public struct CategoryTrendsReport: Hashable, Sendable {
    public let months: [Date]
    /// Categories with any spending, biggest first.
    public let categories: [CategoryTrend]

    public static let otherSubcategory = "Other"

    public static func make(_ transactions: [BankTransaction], endingAt month: Date, count: Int = 6, calculator: BudgetCalculator = BudgetCalculator()) -> CategoryTrendsReport {
        let months = Reports.months(endingAt: month, count: count, calculator: calculator)
        var byCategory: [String: [Decimal]] = [:]
        var bySub: [String: [String: [Decimal]]] = [:]
        for (index, month) in months.enumerated() {
            for transaction in transactions where calculator.isInMonth(transaction.date, month) {
                for allocation in Reports.allocations(of: transaction, calculator: calculator) {
                    byCategory[allocation.category, default: Array(repeating: 0, count: months.count)][index] += allocation.amount
                    let sub = allocation.subcategory ?? otherSubcategory
                    bySub[allocation.category, default: [:]][sub, default: Array(repeating: 0, count: months.count)][index] += allocation.amount
                }
            }
        }
        var categories: [CategoryTrend] = []
        for (name, monthly) in byCategory {
            let trend = SpendingTrend(name: name, monthly: monthly)
            guard trend.total > 0 else { continue }
            var subs: [SpendingTrend] = []
            for (sub, values) in bySub[name] ?? [:] {
                let subTrend = SpendingTrend(name: sub, monthly: values)
                if subTrend.total != 0 { subs.append(subTrend) }
            }
            subs.sort { $0.total > $1.total }
            // A single "Other" line just repeats the category.
            let named = subs.contains { $0.name != otherSubcategory } ? subs : []
            categories.append(CategoryTrend(category: trend, subcategories: named))
        }
        categories.sort { $0.category.total > $1.category.total }
        return CategoryTrendsReport(months: months, categories: categories)
    }
}

/// Spending at one shop.
public struct ShopSpending: Identifiable, Hashable, Sendable {
    public var id: String { key }
    /// The grouping key, such as "TESCO STORES".
    public let key: String
    /// A readable name, such as "Tesco Stores".
    public let name: String
    public let total: Decimal
    /// How many purchases, not counting refunds.
    public let visits: Int
    public let lastVisit: Date
    /// The category most of the spending went to.
    public let category: String
    public var averageVisit: Decimal { visits > 0 ? total / Decimal(visits) : 0 }
}

/// Where the money goes, shop by shop.
public enum TopShops {
    /// Shops ranked by spending between two dates, optionally within one category or
    /// sub-category. Refunds reduce a shop's total; transfers are left out.
    public static func make(_ transactions: [BankTransaction], from: Date, to: Date, category: String? = nil, subcategory: String? = nil,
                            limit: Int? = nil, calculator: BudgetCalculator = BudgetCalculator()) -> [ShopSpending] {
        struct Tally { var total: Decimal = 0; var visits = 0; var last = Date.distantPast; var categories: [String: Decimal] = [:] }
        var tallies: [String: Tally] = [:]
        for transaction in transactions where transaction.date >= from && transaction.date <= to {
            let allocations = Reports.allocations(of: transaction, calculator: calculator).filter { allocation in
                (category == nil || allocation.category == category)
                    && (subcategory == nil || (allocation.subcategory ?? CategoryTrendsReport.otherSubcategory) == subcategory)
            }
            guard !allocations.isEmpty else { continue }
            let key = Categoriser.merchantKey(transaction.merchant).isEmpty ? transaction.merchant.uppercased() : Categoriser.merchantKey(transaction.merchant)
            var tally = tallies[key] ?? Tally()
            for allocation in allocations {
                tally.total += allocation.amount
                tally.categories[allocation.category, default: 0] += allocation.amount
            }
            if transaction.amount < 0 { tally.visits += 1 }
            tally.last = max(tally.last, transaction.date)
            tallies[key] = tally
        }
        let shops = tallies
            .filter { $0.value.total > 0 }
            .map { key, tally in
                ShopSpending(key: key, name: Reports.readableName(key), total: tally.total, visits: tally.visits, lastVisit: tally.last,
                             category: tally.categories.max { $0.value < $1.value }?.key ?? "Uncategorised")
            }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.name < $1.name }
        return limit.map { Array(shops.prefix($0)) } ?? shops
    }
}

/// A look back over a calendar year.
public struct YearInReview: Hashable, Sendable {
    public let year: Int
    public let cashFlow: CashFlowReport
    public let previousYearSpending: Decimal
    /// The five biggest categories.
    public let topCategories: [(category: String, amount: Decimal)]
    public let topShops: [ShopSpending]
    /// The shop visited most often.
    public let mostVisited: ShopSpending?
    public let biggestPurchase: BankTransaction?
    public let payments: Int
    /// The month with the most spending, and the one with the least (of months with any).
    public let busiestMonth: MonthFlow?
    public let quietestMonth: MonthFlow?

    public var spendingChange: Decimal { cashFlow.totalSpending - previousYearSpending }

    public static func == (lhs: YearInReview, rhs: YearInReview) -> Bool {
        lhs.year == rhs.year && lhs.cashFlow == rhs.cashFlow && lhs.topShops == rhs.topShops && lhs.payments == rhs.payments
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(year)
        hasher.combine(cashFlow)
        hasher.combine(payments)
    }

    public static func make(_ transactions: [BankTransaction], year: Int, calculator: BudgetCalculator = BudgetCalculator()) -> YearInReview {
        let calendar = calculator.calendar
        let december = calendar.date(from: DateComponents(year: year, month: 12, day: 15)) ?? Date()
        let months = Reports.months(endingAt: december, count: 12, calculator: calculator)
        let flows = months.map { month in
            MonthFlow(month: month,
                      income: calculator.income(transactions, month: month),
                      spending: calculator.spendingByCategory(transactions, month: month).values.reduce(0, +))
        }
        let previousSpending = Reports.months(endingAt: calendar.date(byAdding: .year, value: -1, to: december) ?? december, count: 12, calculator: calculator)
            .reduce(Decimal(0)) { $0 + calculator.spendingByCategory(transactions, month: $1).values.reduce(0, +) }
        let inYear = transactions.filter { transaction in months.contains { calculator.isInMonth(transaction.date, $0) } }
        var totals: [String: Decimal] = [:]
        for transaction in inYear {
            for allocation in Reports.allocations(of: transaction, calculator: calculator) { totals[allocation.category, default: 0] += allocation.amount }
        }
        let interval = DateInterval(start: calculator.monthInterval(for: months.first ?? december).start, end: calculator.monthInterval(for: december).end)
        let shops = TopShops.make(inYear, from: interval.start, to: interval.end, calculator: calculator)
        let active = flows.filter { $0.spending > 0 }
        return YearInReview(
            year: year,
            cashFlow: CashFlowReport(months: flows),
            previousYearSpending: previousSpending,
            topCategories: totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(5).map { (category: $0.key, amount: $0.value) },
            topShops: Array(shops.prefix(5)),
            mostVisited: shops.max { $0.visits != $1.visits ? $0.visits < $1.visits : $0.total < $1.total },
            biggestPurchase: inYear.filter { $0.amount < 0 && !BudgetCalculator.transferCategories.contains($0.category) }.min { $0.amount < $1.amount },
            payments: inYear.filter { $0.amount < 0 && !BudgetCalculator.transferCategories.contains($0.category) }.count,
            busiestMonth: active.max { $0.spending < $1.spending },
            quietestMonth: active.min { $0.spending < $1.spending }
        )
    }

    /// The years with any payments, newest first.
    public static func years(in transactions: [BankTransaction], calendar: Calendar = .current) -> [Int] {
        Set(transactions.map { calendar.component(.year, from: $0.date) }).sorted(by: >)
    }
}

// MARK: Exports

public extension CashFlowReport {
    func csv(calendar: Calendar = .current) -> String {
        var text = "Month,Income,Spending,Net\r\n"
        for flow in months {
            let month = calendar.dateComponents([.year, .month], from: flow.month)
            text += String(format: "%04d-%02d", month.year ?? 0, month.month ?? 0) + ",\(flow.income),\(flow.spending),\(flow.net)\r\n"
        }
        text += "Total,\(totalIncome),\(totalSpending),\(net)\r\n"
        return text
    }
}

public extension CategoryTrendsReport {
    /// One row per category and sub-category, one column per month.
    func csv(calendar: Calendar = .current) -> String {
        let headers = months.map { month -> String in
            let parts = calendar.dateComponents([.year, .month], from: month)
            return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        }
        var text = "Category,Sub-category," + headers.joined(separator: ",") + ",Total\r\n"
        for trend in categories {
            text += "\(CSVExporter.escape(trend.category.name)),," + trend.category.monthly.map { "\($0)" }.joined(separator: ",") + ",\(trend.category.total)\r\n"
            for sub in trend.subcategories {
                text += "\(CSVExporter.escape(trend.category.name)),\(CSVExporter.escape(sub.name))," + sub.monthly.map { "\($0)" }.joined(separator: ",") + ",\(sub.total)\r\n"
            }
        }
        return text
    }
}

public extension TopShops {
    static func csv(_ shops: [ShopSpending], calendar: Calendar = .current) -> String {
        var text = "Shop,Category,Total,Visits,Average,Last visit\r\n"
        for shop in shops {
            let last = calendar.dateComponents([.year, .month, .day], from: shop.lastVisit)
            let date = String(format: "%04d-%02d-%02d", last.year ?? 0, last.month ?? 0, last.day ?? 0)
            text += "\(CSVExporter.escape(shop.name)),\(CSVExporter.escape(shop.category)),\(shop.total),\(shop.visits),\(Reports.rounded(shop.averageVisit)),\(date)\r\n"
        }
        return text
    }
}

// MARK: Helpers

public enum Reports {
    struct Allocation { let category: String; let subcategory: String?; let amount: Decimal }

    /// The budget months ending at `month`, oldest first.
    public static func months(endingAt month: Date, count: Int, calculator: BudgetCalculator) -> [Date] {
        (0..<max(count, 1)).reversed().compactMap { calculator.calendar.date(byAdding: .month, value: -$0, to: month) }
    }

    /// Signed spending per category, with the sub-category when the whole payment has one.
    /// Receipt splits carry a category only.
    static func allocations(of transaction: BankTransaction, calculator: BudgetCalculator) -> [Allocation] {
        let subcategory = transaction.splits.isEmpty ? transaction.subcategory.flatMap { $0.isEmpty ? nil : $0 } : nil
        return calculator.allocations(of: transaction).map { Allocation(category: $0.0, subcategory: subcategory, amount: $0.1) }
    }

    /// "TESCO STORES" → "Tesco Stores". Short all-capital words such as "BP" or "M&S" stay as they are.
    public static func readableName(_ key: String) -> String {
        key.split(separator: " ").map { word -> String in
            let text = String(word)
            let hasVowel = text.lowercased().contains { "aeiouy".contains($0) }
            if text.count <= 2 || text.contains("&") || !hasVowel { return text }
            return text.prefix(1).uppercased() + text.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    static func rounded(_ value: Decimal, places: Int = 2) -> Decimal {
        var value = value
        var result = Decimal()
        NSDecimalRound(&result, &value, places, .plain)
        return result
    }
}
