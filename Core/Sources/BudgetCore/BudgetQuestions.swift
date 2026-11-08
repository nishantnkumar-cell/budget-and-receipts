import Foundation

// "Ask your budget": questions in your own words, answered on the device. The facts are
// worked out here, exactly; Apple's on-device model only puts them into a sentence, and when
// it isn't available these simple answers stand in.

/// The figures a question can be answered from, already worked out and formatted.
public struct BudgetFacts: Sendable {
    public struct Line: Sendable {
        public let name: String
        public let spent: Decimal
        public let limit: Decimal?
    }

    public let monthName: String
    public let spending: Decimal
    public let income: Decimal
    public let categories: [Line]
    /// Shops this month, biggest first: name, total, visits.
    public let shops: [(name: String, amount: Decimal, visits: Int)]
    /// Last month's spending per category, to compare.
    public let previousCategories: [String: Decimal]
    public let safeToSpendToday: Decimal?
    public let leftThisMonth: Decimal?
    public var billsStillToCome: Decimal = 0
    public let bills: [(name: String, date: Date, amount: Decimal)]
    public let currency: String

    public init(monthName: String, spending: Decimal, income: Decimal, categories: [Line], shops: [(name: String, amount: Decimal, visits: Int)],
                previousCategories: [String: Decimal], safeToSpendToday: Decimal?, leftThisMonth: Decimal?,
                bills: [(name: String, date: Date, amount: Decimal)], currency: String) {
        self.monthName = monthName
        self.spending = spending
        self.income = income
        self.categories = categories
        self.shops = shops
        self.previousCategories = previousCategories
        self.safeToSpendToday = safeToSpendToday
        self.leftThisMonth = leftThisMonth
        self.bills = bills
        self.currency = currency
    }

    /// Builds the facts for a month from payments, budgets and what's coming up.
    public static func make(transactions: [BankTransaction], budgets: [MonthlyBudget], month: Date, calculator: BudgetCalculator,
                            safeToSpend: SafeToSpend?, bills: [UpcomingItem], currency: String) -> BudgetFacts {
        let report = calculator.report(transactions, budgets: budgets, month: month)
        let previousMonth = calculator.calendar.date(byAdding: .month, value: -1, to: month) ?? month
        var shops: [String: (amount: Decimal, visits: Int)] = [:]
        for transaction in transactions where calculator.isInMonth(transaction.date, month) {
            let spent = calculator.allocations(of: transaction).reduce(Decimal(0)) { $0 + $1.1 }
            guard spent != 0 else { continue }
            let key = Categoriser.merchantKey(transaction.merchant).capitalized
            let name = key.isEmpty ? transaction.merchant : key
            shops[name, default: (0, 0)].amount += spent
            if transaction.amount < 0 { shops[name, default: (0, 0)].visits += 1 }
        }
        var facts = BudgetFacts(
            monthName: month.formatted(.dateTime.month(.wide).year()),
            spending: report.spending,
            income: report.income,
            categories: report.lines.filter { $0.spent != 0 || $0.limit != nil }.map { Line(name: $0.category, spent: $0.spent, limit: $0.isTentative ? nil : $0.limit) },
            shops: shops.map { ($0.key, $0.value.amount, $0.value.visits) }.sorted { $0.amount > $1.amount },
            previousCategories: calculator.spendingByCategory(transactions, month: previousMonth),
            safeToSpendToday: safeToSpend?.today,
            leftThisMonth: safeToSpend?.left,
            bills: bills.filter { $0.kind == .payment }.prefix(8).map { ($0.vendor, $0.date, $0.amount ?? 0) },
            currency: currency
        )
        facts.billsStillToCome = safeToSpend?.billsStillToCome ?? 0
        return facts
    }

    private func money(_ value: Decimal) -> String { value.formatted(.currency(code: currency)) }

    /// The facts as plain lines for the on-device model. Every number is final; it only words them.
    public var sheet: String {
        var lines = ["Month: \(monthName)", "Spent this month: \(money(spending))", "Money in this month: \(money(income))"]
        if let leftThisMonth { lines.append("Left in this month's budgets: \(money(leftThisMonth))") }
        if let safeToSpendToday { lines.append("Safe to spend per day for the rest of the month, after bills: \(money(safeToSpendToday))") }
        lines.append("Categories this month:")
        for line in categories.prefix(16) {
            var text = "- \(line.name): spent \(money(line.spent)) so far"
            if let limit = line.limit {
                let left = limit - line.spent
                text += left >= 0 ? "; budget \(money(limit)), \(money(left)) still left" : "; budget \(money(limit)), over budget by \(money(-left)), nothing left"
            } else {
                text += "; no budget set"
            }
            text += "; last month spent \(money(previousCategories[line.name] ?? 0))."
            lines.append(text)
        }
        if !shops.isEmpty {
            lines.append("Shops this month (total, visits):")
            for shop in shops.prefix(20) { lines.append("- \(shop.name): \(money(shop.amount)), \(shop.visits) visit\(shop.visits == 1 ? "" : "s")") }
        }
        if !bills.isEmpty {
            lines.append("Bills coming up:")
            for bill in bills { lines.append("- \(bill.name) on \(bill.date.formatted(.dateTime.weekday(.wide).day().month(.wide))): \(money(bill.amount))") }
        }
        return lines.joined(separator: "\n")
    }

    /// "Can I afford £50 …?": worked out exactly, never left to the model. Nil when the
    /// question isn't one, or names no amount.
    public func affordAnswer(to question: String) -> String? {
        let words = question.lowercased()
        guard words.contains("afford") || words.contains("can i spend") || words.contains("can i buy") else { return nil }
        guard let range = words.range(of: #"\d+(?:[.,]\d{1,2})?"#, options: .regularExpression),
              let amount = Decimal(string: words[range].replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        if let category = categories.first(where: { words.contains($0.name.lowercased()) }), let limit = category.limit {
            let left = limit - category.spent
            return left >= amount
                ? "Yes. \(money(amount)) fits: \(category.name) has \(money(left)) left this month."
                : "Not within the \(category.name) budget: it has \(money(max(left, 0))) left this month."
        }
        guard let leftThisMonth else { return "Set some budgets first, then I can say what you can afford." }
        let free = leftThisMonth - billsStillToCome
        return free >= amount
            ? "Yes. After the bills still to come you have \(money(free)) left in this month's budgets\(safeToSpendToday.map { ", about \(money($0)) a day" } ?? "")."
            : "It would take you over this month's budgets: after the bills still to come, \(money(max(free, 0))) is left."
    }

    /// An answer worked out without the model, for the common questions. Nil when the question
    /// needs the model to understand it.
    public func simpleAnswer(to question: String) -> String? {
        if let afford = affordAnswer(to: question) { return afford }
        let words = question.lowercased()
        if let category = categories.first(where: { words.contains($0.name.lowercased()) || $0.name.lowercased().split(separator: " ").first.map { words.contains($0) } == true }) {
            var answer = "You've spent \(money(category.spent)) on \(category.name) in \(monthName)"
            if let limit = category.limit {
                let left = limit - category.spent
                answer += left >= 0 ? ", with \(money(left)) left of \(money(limit))." : ", \(money(-left)) over the \(money(limit)) budget."
            } else {
                answer += "."
            }
            return answer
        }
        if let shop = shops.first(where: { words.contains($0.name.lowercased()) }) {
            return "You've spent \(money(shop.amount)) at \(shop.name) in \(monthName), over \(shop.visits) visit\(shop.visits == 1 ? "" : "s")."
        }
        if words.contains("left") || words.contains("safe") || words.contains("afford") {
            guard let leftThisMonth else { return "Set some budgets first, then I can say what's left." }
            var answer = "You have \(money(leftThisMonth)) left in this month's budgets"
            if let safeToSpendToday { answer += ", about \(money(safeToSpendToday)) a day after the bills still to come" }
            return answer + "."
        }
        if words.contains("bill") || words.contains("due") || words.contains("coming up") {
            guard let next = bills.first else { return "No bills are due soon." }
            return "Next is \(next.name), \(money(next.amount)) on \(next.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))."
        }
        if words.contains("spent") || words.contains("spend") || words.contains("spending") {
            return "You've spent \(money(spending)) in \(monthName)" + (income > 0 ? ", with \(money(income)) coming in." : ".")
        }
        return nil
    }
}

