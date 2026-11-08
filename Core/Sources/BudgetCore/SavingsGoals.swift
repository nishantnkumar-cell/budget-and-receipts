import Foundation

/// Something you're saving up for, on your own or together: a holiday, a deposit, a new car.
public struct SavingsGoal: Identifiable, Codable, Hashable, Sendable {
    public struct Contribution: Identifiable, Codable, Hashable, Sendable {
        public var id: UUID
        public var date: Date
        /// Money put in. Negative for money taken back out.
        public var amount: Decimal
        /// Who put it in, for a shared goal. Nil means you.
        public var by: Person?
        public var note: String?

        public init(id: UUID = UUID(), date: Date = Date(), amount: Decimal, by: Person? = nil, note: String? = nil) {
            self.id = id
            self.date = date
            self.amount = amount
            self.by = by
            self.note = note
        }
    }

    public var id: UUID
    public var name: String
    public var target: Decimal
    /// When you'd like to have it by. Optional.
    public var deadline: Date?
    /// Whose goal it is: yours, your partner's, or shared (both of you). Nil is shared.
    public var owner: MoneyOwner?
    public var isPrivate: Bool?
    /// An SF Symbol name for the goal, picked from `SavingsGoal.symbols`.
    public var symbol: String?
    public var contributions: [Contribution]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, target: Decimal, deadline: Date? = nil, owner: MoneyOwner? = nil,
                isPrivate: Bool? = nil, symbol: String? = nil, contributions: [Contribution] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.target = target
        self.deadline = deadline
        self.owner = owner
        self.isPrivate = isPrivate
        self.symbol = symbol
        self.contributions = contributions
        self.createdAt = createdAt
    }

    /// Symbols offered for a goal, all SF Symbols in the outline style the app uses.
    public static let symbols = ["star", "airplane", "house", "car", "gift", "graduationcap", "heart", "umbrella", "laptopcomputer", "pawprint"]

    public var saved: Decimal { contributions.reduce(0) { $0 + $1.amount } }
    public var remaining: Decimal { max(target - saved, 0) }
    public var isReached: Bool { target > 0 && saved >= target }

    /// How far along, from 0 to 1.
    public var progress: Double {
        guard target > 0 else { return 0 }
        return min(max(NSDecimalNumber(decimal: saved / target).doubleValue, 0), 1)
    }

    /// What each person has put in.
    public func saved(by person: Person) -> Decimal {
        contributions.filter { ($0.by ?? .me) == person }.reduce(0) { $0 + $1.amount }
    }

    /// What to put in each month from `today` to reach the target by the deadline, to the
    /// penny and rounded up. Nil without a deadline, or once reached. The deadline's own month
    /// counts, so a deadline this month asks for everything left now.
    public func monthlyNeeded(today: Date = Date(), calendar: Calendar = .current) -> Decimal? {
        guard let deadline, !isReached else { return nil }
        let months = max((calendar.dateComponents([.month], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: deadline)).month ?? 0) + 1, 1)
        var monthly = remaining / Decimal(months)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &monthly, 2, .up)
        return rounded
    }

    /// The day the goal is reached at the pace of the last three months' contributions. Nil
    /// with nothing put in lately, or once reached.
    public func projectedDate(today: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard !isReached, let since = calendar.date(byAdding: .month, value: -3, to: today) else { return nil }
        let recent = contributions.filter { $0.date > since && $0.date <= today }.reduce(Decimal(0)) { $0 + $1.amount }
        guard recent > 0 else { return nil }
        let monthsToGo = NSDecimalNumber(decimal: remaining / (recent / 3)).doubleValue
        return calendar.date(byAdding: .day, value: Int((monthsToGo * 30.44).rounded(.up)), to: today)
    }

    /// True when the projected date is after the deadline.
    public func isBehind(today: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let deadline, !isReached else { return false }
        guard let projected = projectedDate(today: today, calendar: calendar) else { return today > deadline || !contributions.isEmpty }
        return projected > deadline
    }
}
