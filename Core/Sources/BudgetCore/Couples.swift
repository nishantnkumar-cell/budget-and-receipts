import Foundation

/// One of the two people in a couple. Statements are imported from "me"'s accounts.
public enum Person: String, Codable, CaseIterable, Hashable, Sendable {
    case me, partner

    public var other: Person { self == .me ? .partner : .me }
}

/// Whose money a transaction, split or receipt item is.
public enum MoneyOwner: String, Codable, CaseIterable, Hashable, Sendable {
    case mine, partner, shared
}

/// Which side of the household a screen is showing: the Me / Partner / Together switch.
public enum HouseholdView: String, Codable, CaseIterable, Hashable, Sendable {
    case me, partner, together
}

/// Picks an owner for transactions that have none set, by merchant name or category.
public struct OwnerRule: Identifiable, Codable, Hashable, Sendable {
    public enum Match: Codable, Hashable, Sendable {
        /// The merchant name contains this text (ignoring case and accents).
        case merchant(String)
        case category(String)
    }

    public var id: UUID
    public var match: Match
    public var owner: MoneyOwner

    public init(id: UUID = UUID(), match: Match, owner: MoneyOwner) {
        self.id = id
        self.match = match
        self.owner = owner
    }

    func matches(_ transaction: BankTransaction) -> Bool {
        switch match {
        case .merchant(let text):
            let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !needle.isEmpty && transaction.merchant.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .category(let category):
            return transaction.category == category
        }
    }
}

/// How a couple shares money. With no partner set up the app behaves as a single-person budget.
public struct CoupleSettings: Codable, Hashable, Sendable {
    public var partnerName: String
    /// My part of shared costs, from 0 to 1. 0.5 is an even split.
    public var myShare: Decimal
    public var rules: [OwnerRule]
    /// The owner for transactions that no rule matches.
    public var defaultOwner: MoneyOwner
    /// The household owner's own name, so the partner's app can say who "they" are.
    public var ownerName: String?

    public init(partnerName: String = "", myShare: Decimal = Decimal(string: "0.5")!, rules: [OwnerRule] = [], defaultOwner: MoneyOwner = .mine) {
        self.partnerName = partnerName
        self.myShare = myShare
        self.rules = rules
        self.defaultOwner = defaultOwner
    }

    /// Splits shared costs in proportion to income, e.g. 3,000 and 2,000 gives me 60%.
    public static func share(myIncome: Decimal, partnerIncome: Decimal) -> Decimal {
        let total = myIncome + partnerIncome
        guard myIncome >= 0, partnerIncome >= 0, total > 0 else { return Decimal(string: "0.5")! }
        return myIncome / total
    }
}

/// Money one person handed the other to settle up.
public struct Settlement: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    public var from: Person
    public var amount: Decimal
    public var note: String

    public init(id: UUID = UUID(), date: Date, from: Person, amount: Decimal, note: String = "") {
        self.id = id
        self.date = date
        self.from = from
        self.amount = amount
        self.note = note
    }
}

/// The running who-owes-whom total between the two people.
public struct CoupleBalance: Hashable, Sendable {
    /// Positive when my partner owes me, negative when I owe my partner. Not rounded.
    public let amount: Decimal

    public init(amount: Decimal) { self.amount = amount }

    /// Rounded to the penny, which is what a person can actually pay.
    public var rounded: Decimal {
        var value = amount
        var result = Decimal()
        NSDecimalRound(&result, &value, 2, .bankers)
        return result
    }

    /// Who should pay, or nil when the two are square.
    public var debtor: Person? {
        if rounded > 0 { return .partner }
        if rounded < 0 { return .me }
        return nil
    }

    /// How much the debtor should pay.
    public var amountOwed: Decimal { rounded < 0 ? -rounded : rounded }
}

/// The couple rules: whose money each transaction is, each person's share of it,
/// and who owes whom. Foundation-only so every app gets the same answers.
public struct CoupleLedger: Sendable {
    public var settings: CoupleSettings
    public var calculator: BudgetCalculator

    public init(settings: CoupleSettings, calculator: BudgetCalculator = BudgetCalculator()) {
        self.settings = settings
        self.calculator = calculator
    }

    private var myShare: Decimal { min(max(settings.myShare, 0), 1) }

    /// The owner set on the transaction, else the first merchant rule that matches,
    /// else the first category rule, else the default. Merchant rules win because they
    /// are more specific ("Netflix is mine" beats "Subscriptions are shared").
    /// Whose each bank account is (a partner's or joint account), so its payments follow it.
    public var accountOwners: [UUID: MoneyOwner] = [:]

    /// Set by hand first, then the account's owner (a joint or partner's account), then the rules.
    public func owner(of transaction: BankTransaction) -> MoneyOwner {
        if let owner = transaction.owner { return owner }
        if let account = transaction.accountID, let owner = accountOwners[account], owner != .mine { return owner }
        return ruleOwner(of: transaction)
    }

    /// Why a transaction counts as whoever's it is, for explaining it in the app.
    public enum OwnerSource: Hashable, Sendable {
        case manual
        /// A joint or partner's account.
        case account(UUID)
        case merchantRule
        case categoryRule
        case `default`
    }

    public func ownerSource(of transaction: BankTransaction) -> OwnerSource {
        if transaction.owner != nil { return .manual }
        if let account = transaction.accountID, let owner = accountOwners[account], owner != .mine { return .account(account) }
        if let rule = settings.rules.first(where: { if case .merchant = $0.match { $0.matches(transaction) } else { false } }), rule.matches(transaction) { return .merchantRule }
        if settings.rules.contains(where: { if case .category = $0.match { $0.matches(transaction) } else { false } }) { return .categoryRule }
        return .default
    }

    /// The owner the rules give, ignoring any owner set by hand.
    public func ruleOwner(of transaction: BankTransaction) -> MoneyOwner {
        let merchantRules = settings.rules.filter { if case .merchant = $0.match { true } else { false } }
        let categoryRules = settings.rules.filter { if case .category = $0.match { true } else { false } }
        return (merchantRules + categoryRules).first { $0.matches(transaction) }?.owner ?? settings.defaultOwner
    }

    /// The fraction of money with this owner that counts towards a person or the household.
    public func share(of owner: MoneyOwner, for view: HouseholdView) -> Decimal {
        switch (view, owner) {
        case (.together, _): 1
        case (.me, .mine), (.partner, .partner): 1
        case (.me, .partner), (.partner, .mine): 0
        case (.me, .shared): myShare
        case (.partner, .shared): 1 - myShare
        }
    }

    private func share(of owner: MoneyOwner, person: Person) -> Decimal {
        share(of: owner, for: person == .me ? HouseholdView.me : .partner)
    }

    /// The transactions as one view sees them: each amount and split scaled to that
    /// view's share, and anything with no share left out. Pass the result to
    /// `BudgetCalculator` to get budgets and reports for Me, Partner or Together.
    public func transactions(_ transactions: [BankTransaction], for view: HouseholdView) -> [BankTransaction] {
        guard view != .together else { return transactions }
        return transactions.compactMap { transaction in
            let whole = owner(of: transaction)
            var scaled = transaction
            if transaction.splits.isEmpty {
                scaled.amount = transaction.amount * share(of: whole, for: view)
            } else {
                scaled.splits = transaction.splits.compactMap { split in
                    var part = split
                    part.amount = split.amount * share(of: split.owner ?? whole, for: view)
                    return part.amount == 0 ? nil : part
                }
                let total = scaled.splits.reduce(Decimal(0)) { $0 + $1.amount }
                scaled.amount = transaction.amount < 0 ? -total : total
            }
            return scaled.amount == 0 ? nil : scaled
        }
    }

    /// Who paid a transaction: as set, else whose account it came from. Nil for a joint account,
    /// whose money is both of yours in your shares of shared costs.
    public func payer(of transaction: BankTransaction) -> Person? {
        if let paidBy = transaction.paidBy { return paidBy }
        switch transaction.accountID.flatMap({ accountOwners[$0] }) {
        case .partner: return .partner
        case .shared: return nil
        case .mine, nil: return .me
        }
    }

    /// Who owes whom: what I paid less my fair part of it, added up. Whoever paid is owed the
    /// other person's share of what they paid for; a refund reverses that. A joint account paid
    /// in your shares of shared costs, so shared spending from it leaves you square, while your
    /// own spending from it is owed back to your partner. Income and transfers are left out.
    /// Settlements count from the day they are recorded.
    public func balance(_ transactions: [BankTransaction], settlements: [Settlement] = []) -> CoupleBalance {
        var owedToMe: Decimal = 0
        for transaction in transactions {
            let payer = payer(of: transaction)
            for (owner, spent) in parts(of: transaction) {
                let paidByMe: Decimal = switch payer {
                case .me: spent
                case .partner: 0
                case nil: spent * myShare
                }
                owedToMe += paidByMe - spent * share(of: owner, person: .me)
            }
        }
        for settlement in settlements {
            owedToMe += settlement.from == .partner ? -settlement.amount : settlement.amount
        }
        return CoupleBalance(amount: owedToMe)
    }

    /// Budgets as one view sees them. Together sees them in full. Me and Partner see their share
    /// of shared costs, or all or none of a category a category rule gives to one of you.
    public func budgets(_ budgets: [MonthlyBudget], for view: HouseholdView) -> [MonthlyBudget] {
        guard view != .together else { return budgets }
        return budgets.map { budget in
            let owner = settings.rules.first { if case .category(let category) = $0.match { category == budget.category } else { false } }?.owner ?? .shared
            var scaled = budget
            scaled.limit = budget.limit * share(of: owner, for: view)
            return scaled
        }
    }

    /// Spending split by owner: positive for a purchase, negative for a refund.
    func parts(of transaction: BankTransaction) -> [(MoneyOwner, Decimal)] {
        let allocations = calculator.allocations(of: transaction)
        guard !allocations.isEmpty else { return [] }
        let whole = owner(of: transaction)
        guard !transaction.splits.isEmpty else { return allocations.map { (whole, $0.1) } }
        let sign: Decimal = transaction.amount < 0 ? 1 : -1
        return transaction.splits.map { ($0.owner ?? whole, $0.amount * sign) }
    }
}
