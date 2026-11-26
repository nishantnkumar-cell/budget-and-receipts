import BudgetCore
import Foundation

public enum IndiaBank: String, Codable, CaseIterable, Sendable {
    case icici, sbi, other

    public var title: String {
        switch self {
        case .icici: "ICICI Bank"
        case .sbi: "State Bank of India"
        case .other: "Another bank"
        }
    }

    public var shortTitle: String {
        switch self {
        case .icici: "ICICI"
        case .sbi: "SBI"
        case .other: "Bank"
        }
    }
}

/// A rupee account. Kept apart from the budget's accounts, so rupees are never added to pounds.
public struct IndiaAccount: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case nre, nro, resident, deposit

        public var title: String {
            switch self {
            case .nre: "NRE"
            case .nro: "NRO"
            case .resident: "Resident savings"
            case .deposit: "Fixed deposit"
            }
        }
    }

    public var id: String
    public var bank: IndiaBank
    public var kind: Kind
    /// Only the last four digits are ever kept.
    public var lastFour: String {
        didSet { if lastFour != BankAccount.lastFour(lastFour) { lastFour = BankAccount.lastFour(lastFour) } }
    }
    public var nickname: String
    public var owner: MoneyOwner
    /// Hidden, with its lines, from a partner the household is shared with.
    public var isPrivate: Bool
    /// When you last made it private or shared it, so an out-of-date copy from another device
    /// can't undo that.
    public var privacyChangedAt: Date?
    /// A balance typed in, for an account without statements such as a deposit.
    public var statedBalance: Decimal?
    public var statedOn: Date?

    public init(id: String = UUID().uuidString, bank: IndiaBank, kind: Kind, lastFour: String = "", nickname: String = "",
                owner: MoneyOwner = .mine, isPrivate: Bool = false, statedBalance: Decimal? = nil, statedOn: Date? = nil) {
        self.id = id
        self.bank = bank
        self.kind = kind
        self.lastFour = BankAccount.lastFour(lastFour)
        self.nickname = nickname
        self.owner = owner
        self.isPrivate = isPrivate
        self.statedBalance = statedBalance
        self.statedOn = statedOn
    }

    /// "ICICI NRE ••1234", or the name you gave it.
    public var title: String {
        if !nickname.isEmpty { return nickname }
        let ending = lastFour.isEmpty ? "" : " ••\(lastFour)"
        return "\(bank.shortTitle) \(kind.title)\(ending)"
    }

    /// The part of this account's income taxed on a person: half each for a joint account.
    public func share(of person: Person) -> Decimal {
        switch owner {
        case .mine: person == .me ? 1 : 0
        case .partner: person == .partner ? 1 : 0
        case .shared: Decimal(1) / 2
        }
    }
}

/// One line of a rupee account: from a statement, or typed in.
public struct IndiaEntry: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case other, interest, taxDeducted, dividend, dividendTax

        public var title: String {
            switch self {
            case .other: "Other"
            case .interest: "Interest"
            case .taxDeducted: "Tax deducted on interest (TDS)"
            case .dividend: "Dividend, before tax"
            case .dividendTax: "Tax deducted on dividends (TDS)"
            }
        }

        public var isTax: Bool { self == .taxDeducted || self == .dividendTax }
    }

    public var id: String
    public var accountID: String
    public var date: Date
    public var narration: String
    /// Rupees: positive for money in, negative for money out.
    public var amount: Decimal
    /// The balance after this line, from the statement.
    public var balance: Decimal?
    /// What you said it is. Nil means the guess from the wording.
    public var chosenKind: Kind?
    /// Typed in, e.g. interest from an interest certificate. It doesn't move the balance.
    public var isManual: Bool

    public init(id: String, accountID: String, date: Date, narration: String, amount: Decimal, balance: Decimal? = nil,
                chosenKind: Kind? = nil, isManual: Bool = false) {
        self.id = id
        self.accountID = accountID
        self.date = date
        self.narration = narration
        self.amount = amount
        self.balance = balance
        self.chosenKind = chosenKind
        self.isManual = isManual
    }

    /// Interest, a dividend or tax typed in from a certificate. Amounts are given as positive rupees.
    public static func manual(accountID: String, date: Date, kind: Kind, rupees: Decimal, note: String = "") -> IndiaEntry {
        IndiaEntry(id: "manual|\(UUID().uuidString)", accountID: accountID, date: date, narration: note.isEmpty ? kind.title : note,
                   amount: kind.isTax ? -abs(rupees) : abs(rupees), chosenKind: kind, isManual: true)
    }

    public var kind: Kind { chosenKind ?? Self.guess(narration: narration, amount: amount) }

    /// Only the banks' own wording counts, so a payment someone labelled "interest" isn't
    /// mistaken for it.
    public static func guess(narration: String, amount: Decimal) -> Kind {
        let words = " " + narration.uppercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { words.contains(" \($0) ") } }
        if amount < 0, has(["TDS", "TAX DEDUCTED", "TAX DEDUCTION"]) { return .taxDeducted }
        if amount > 0, has(["INT PD", "INTPD", "CREDIT INTEREST", "INTEREST CREDIT", "INTEREST PAID", "INT CR", "SB INT", "FD INT", "INT ON FD", "INTEREST ON"]) {
            return .interest
        }
        return .other
    }
}

/// Rupees to one pound, entered by you: one average for each UK tax year, and one for today's balances.
public struct IndiaRate: Codable, Hashable, Sendable, Identifiable {
    public static let balancesID = "balances"

    /// A tax year such as "2025-26", or `balancesID`.
    public var id: String
    public var rupeesPerPound: Decimal

    public init(id: String, rupeesPerPound: Decimal) {
        self.id = id
        self.rupeesPerPound = rupeesPerPound
    }
}

public struct IndiaBook: Hashable, Sendable {
    public var accounts: [IndiaAccount]
    public var entries: [IndiaEntry]
    public var rates: [IndiaRate]

    public init(accounts: [IndiaAccount] = [], entries: [IndiaEntry] = [], rates: [IndiaRate] = []) {
        self.accounts = accounts
        self.entries = entries
        self.rates = rates
    }

    public func account(_ id: String) -> IndiaAccount? { accounts.first { $0.id == id } }

    /// An account's lines, newest first.
    public func entries(of accountID: String) -> [IndiaEntry] {
        entries.filter { $0.accountID == accountID }.sorted { ($1.date, $1.id) < ($0.date, $0.id) }
    }

    public mutating func save(_ account: IndiaAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account } else { accounts.append(account) }
    }

    /// Saves an edit made to a copy of an account taken earlier. Only what the edit changed is
    /// written, so something newer from another device stays (above all, that it's private),
    /// and an account removed meanwhile stays removed.
    public mutating func save(_ draft: IndiaAccount, editedFrom original: IndiaAccount) {
        guard var current = account(original.id) else { return }
        if draft.bank != original.bank { current.bank = draft.bank }
        if draft.kind != original.kind { current.kind = draft.kind }
        if draft.lastFour != original.lastFour { current.lastFour = draft.lastFour }
        if draft.nickname != original.nickname { current.nickname = draft.nickname }
        if draft.owner != original.owner { current.owner = draft.owner }
        if draft.isPrivate != original.isPrivate { current.isPrivate = draft.isPrivate }
        if draft.statedBalance != original.statedBalance || draft.statedOn != original.statedOn {
            current.statedBalance = draft.statedBalance
            current.statedOn = draft.statedOn
        }
        save(current)
    }

    /// Adds a statement's new lines to an account, if it's still there.
    public mutating func add(_ statement: IndiaStatement, to accountID: String) {
        guard account(accountID) != nil else { return }
        entries += statement.entries(for: accountID, existing: entries).new
    }

    public mutating func save(_ entry: IndiaEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
    }

    /// Removes an account and its lines.
    public mutating func deleteAccount(_ id: String) {
        accounts.removeAll { $0.id == id }
        entries.removeAll { $0.accountID == id }
    }

    public func rate(_ id: String) -> Decimal? { rates.first { $0.id == id }?.rupeesPerPound }

    /// Nil or zero removes the rate.
    public mutating func setRate(_ id: String, rupeesPerPound: Decimal?) {
        rates.removeAll { $0.id == id }
        if let value = rupeesPerPound, value > 0 { rates.append(IndiaRate(id: id, rupeesPerPound: value)) }
    }

    /// The latest balance known: the closing balance on the newest statement day, or the one
    /// typed in when that's newer.
    public func balance(of accountID: String) -> (rupees: Decimal, date: Date)? {
        let lines = entries.filter { $0.accountID == accountID && !$0.isManual && $0.balance != nil }
        var fromLines: (rupees: Decimal, date: Date)?
        if let newest = lines.map(\.date).max() {
            let day = lines.filter { TaxYear.calendar.isDate($0.date, inSameDayAs: newest) }
            // The closing line is the one no other line of the day starts from. Banks list a
            // day in either order, so the order in the file isn't trusted.
            var openings: [Decimal: Int] = [:]
            for line in day { openings[line.balance! - line.amount, default: 0] += 1 }
            var closing: [IndiaEntry] = []
            for line in day.sorted(by: { $0.id < $1.id }) {
                if let count = openings[line.balance!], count > 0 { openings[line.balance!] = count - 1 } else { closing.append(line) }
            }
            if let line = closing.last ?? day.max(by: { $0.id < $1.id }) { fromLines = (line.balance!, line.date) }
        }
        if let account = account(accountID), let stated = account.statedBalance, let on = account.statedOn,
           fromLines.map({ on > $0.date }) ?? true {
            return (stated, on)
        }
        return fromLines
    }

    /// The balances of these accounts added up. Accounts with no balance add nothing.
    public func totalBalance(_ accounts: [IndiaAccount]) -> Decimal {
        accounts.reduce(0) { $0 + (balance(of: $1.id)?.rupees ?? 0) }
    }
}

public enum IndiaMoney {
    /// Pounds for an amount in rupees, to the penny. Nil without a rate.
    public static func pounds(_ rupees: Decimal, rupeesPerPound: Decimal?) -> Decimal? {
        guard let rate = rupeesPerPound, rate > 0 else { return nil }
        return TaxMoney.round(rupees / rate, scale: 2, .plain)
    }

    /// "₹12,34,567.50", grouped as in India, the same on every platform.
    public static func format(_ rupees: Decimal) -> String {
        let rounded = TaxMoney.round(rupees, scale: 2, .plain)
        let negative = rounded < 0
        let parts = "\(negative ? -rounded : rounded)".split(separator: ".")
        var whole = String(parts[0])
        var index = whole.count - 3
        while index > 0 {
            whole.insert(",", at: whole.index(whole.startIndex, offsetBy: index))
            index -= 2
        }
        let paise = parts.count > 1 ? String(parts[1]) : ""
        return (negative ? "-₹" : "₹") + whole + "." + paise.padding(toLength: 2, withPad: "0", startingAt: 0)
    }

    /// Reads what a person types: "1,25,000.50", "₹5000". Nil for anything else, including
    /// negative amounts.
    public static func parse(_ text: String) -> Decimal? {
        let cleaned = text.filter { !" ₹,".contains($0) }
        guard cleaned.range(of: #"^\d{1,12}(\.\d{1,4})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }
}
