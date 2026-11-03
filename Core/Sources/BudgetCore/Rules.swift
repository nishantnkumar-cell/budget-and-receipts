import Foundation

// MARK: Sub-categories

public extension FinanceCategories {
    /// The sub-categories of each category. Budgets stay at the category level; sub-categories
    /// show where the money inside a category went.
    static let subcategories: [String: [String]] = [
        "Housing": ["Rent", "Mortgage", "Repairs", "Furniture", "Service charge"],
        "Bills & utilities": ["Energy", "Water", "Phone", "Broadband", "Council tax", "Insurance", "TV licence", "Other bills"],
        "Groceries": ["Supermarket", "Convenience store", "Specialist", "Online grocery"],
        "Eating out": ["Restaurant", "Takeaway", "Coffee", "Fast food", "Pub and bar", "Sweets and bakery"],
        "Transport": ["Fuel", "Parking", "Public transport", "Taxi", "Car costs", "Car insurance"],
        "Shopping": ["Clothes and shoes", "Electronics", "Home and garden", "Online marketplace", "Books"],
        "Health": ["Pharmacy", "Fitness", "Medical", "Dental", "Optician"],
        "Personal care": ["Hair and beauty", "Toiletries", "Spa"],
        "Family": ["Childcare", "School", "Kids", "Pets", "Days out"],
        "Entertainment": ["Cinema and theatre", "Events and tickets", "Hobbies", "Lottery and betting", "Pub and nights out"],
        "Education": ["Courses", "Tuition", "Books and supplies"],
        "Gifts & charity": ["Gifts", "Charity"],
        "Cash": ["ATM withdrawal", "Cashback"],
        "Fees & charges": ["Bank charges", "Interest charged", "Late fees", "Foreign transaction fees"],
        "Subscriptions": ["Streaming", "Music", "Apps and games", "Cloud storage", "News", "Memberships"],
        "Travel": ["Flights", "Hotels", "Holidays", "Trains"],
        "Savings & investments": ["Savings", "Investments", "Pension"],
        "Income": ["Salary", "Refund", "Interest", "Benefits", "Other income"],
        "Card payment": ["Credit card repayment"],
        "Internal transfer": ["Between accounts"],
    ]

    /// The sub-categories for a category, or none.
    static func subcategories(of category: String) -> [String] { subcategories[category] ?? [] }

    /// "Groceries › Supermarket", or just the category.
    static func label(_ category: String, _ subcategory: String?) -> String {
        guard let subcategory, !subcategory.isEmpty else { return category }
        return "\(category) › \(subcategory)"
    }
}

// MARK: Rules

/// A rule that categorises payments, e.g. "Description contains TESCO → Groceries › Supermarket".
/// Rules run in order and the first one that matches wins. They come before what the app has
/// learned and before Apple Intelligence, so a rule always decides. Starter rules ship with the
/// app; people can turn them off, change them or add their own.
public struct CategoryRule: Identifiable, Codable, Hashable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        /// The shop name and the statement description together.
        case description
        /// The amount, compared without its sign.
        case amount
        /// The bank account's name.
        case account

        public var title: String {
            switch self {
            case .description: "Description"
            case .amount: "Amount"
            case .account: "Account"
            }
        }
    }

    public enum Operator: String, Codable, CaseIterable, Sendable {
        case contains, containsAny, startsWith, equals, greaterThan, lessThan, isMoneyIn, isMoneyOut

        public var title: String {
            switch self {
            case .contains: "contains"
            case .containsAny: "contains any of"
            case .startsWith: "starts with"
            case .equals: "is"
            case .greaterThan: "is more than"
            case .lessThan: "is less than"
            case .isMoneyIn: "is money in"
            case .isMoneyOut: "is money out"
            }
        }

        /// Operators that need no value.
        public var needsValue: Bool { self != .isMoneyIn && self != .isMoneyOut }

        public static func available(for field: Field) -> [Operator] {
            switch field {
            case .description: [.contains, .containsAny, .startsWith, .equals]
            case .amount: [.greaterThan, .lessThan, .equals, .isMoneyIn, .isMoneyOut]
            case .account: [.equals, .contains]
            }
        }
    }

    public struct Condition: Codable, Hashable, Sendable {
        public var field: Field
        public var op: Operator
        /// Text to look for (words are matched whole, ignoring case and punctuation), or an
        /// amount. For "contains any of", values are separated by commas.
        public var value: String

        public init(_ field: Field, _ op: Operator, _ value: String = "") {
            self.field = field
            self.op = op
            self.value = value
        }

        public var summary: String {
            op.needsValue ? "\(field.title) \(op.title) \(value)" : "\(field.title) \(op.title)"
        }
    }

    public var id: UUID
    public var name: String
    public var conditions: [Condition]
    /// True: every condition must match. False: any one is enough.
    public var matchAll: Bool
    public var category: String
    public var subcategory: String?
    public var isEnabled: Bool
    /// Shipped with the app (people can still change or turn it off).
    public var isStarter: Bool

    public init(id: UUID = UUID(), name: String, conditions: [Condition], matchAll: Bool = true,
                category: String, subcategory: String? = nil, isEnabled: Bool = true, isStarter: Bool = false) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.matchAll = matchAll
        self.category = category
        self.subcategory = subcategory
        self.isEnabled = isEnabled
        self.isStarter = isStarter
    }

    public var resultLabel: String { FinanceCategories.label(category, subcategory) }

    public func matches(_ transaction: BankTransaction, accountName: String? = nil) -> Bool {
        guard isEnabled, !conditions.isEmpty else { return false }
        let results = conditions.map { Self.check($0, transaction, accountName: accountName) }
        return matchAll ? !results.contains(false) : results.contains(true)
    }

    static func check(_ condition: Condition, _ transaction: BankTransaction, accountName: String?) -> Bool {
        switch condition.field {
        case .description:
            let text = " " + Categoriser.matchWords(transaction.merchant + " " + transaction.description).joined(separator: " ") + " "
            return textMatch(condition, text: text)
        case .account:
            guard let accountName else { return false }
            return textMatch(condition, text: " " + Categoriser.words(accountName).joined(separator: " ") + " ")
        case .amount:
            let size = transaction.amount < 0 ? -transaction.amount : transaction.amount
            let value = Decimal(string: condition.value.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
            switch condition.op {
            case .isMoneyIn: return transaction.amount > 0
            case .isMoneyOut: return transaction.amount < 0
            case .greaterThan: return value.map { size > $0 } ?? false
            case .lessThan: return value.map { size < $0 } ?? false
            case .equals: return value.map { size == $0 } ?? false
            default: return false
            }
        }
    }

    /// Whole-word text matching on normalised words, so "EE" doesn't match "COFFEE".
    private static func textMatch(_ condition: Condition, text: String) -> Bool {
        func phrase(_ value: String) -> String { Categoriser.words(value).joined(separator: " ") }
        switch condition.op {
        case .contains:
            let p = phrase(condition.value)
            return !p.isEmpty && text.contains(" \(p) ")
        case .containsAny:
            return condition.value.split(separator: ",").map { phrase(String($0)) }.contains { !$0.isEmpty && text.contains(" \($0) ") }
        case .startsWith:
            let p = phrase(condition.value)
            return !p.isEmpty && text.hasPrefix(" \(p) ")
        case .equals:
            let p = phrase(condition.value)
            return !p.isEmpty && text == " \(p) "
        default:
            return false
        }
    }
}

public enum RulesEngine {
    /// The first enabled rule that matches, or nil.
    public static func firstMatch(_ rules: [CategoryRule], for transaction: BankTransaction, accountName: String? = nil) -> CategoryRule? {
        rules.first { $0.matches(transaction, accountName: accountName) }
    }

    /// Payments a rule would change: uncategorised ones, plus (when `overwrite`) any it matches.
    public static func matching(_ rule: CategoryRule, in transactions: [BankTransaction], accountNames: [UUID: String] = [:]) -> [BankTransaction] {
        transactions.filter { rule.matches($0, accountName: $0.accountID.flatMap { accountNames[$0] }) }
    }

    /// Runs the rules over payments. Uncategorised payments get the first match; with
    /// `overwrite`, every matching payment is changed. A payment whose category already agrees
    /// with a rule gets that rule's sub-category if it has none. Returns how many changed.
    public static func apply(_ rules: [CategoryRule], to transactions: inout [BankTransaction], accountNames: [UUID: String] = [:], overwrite: Bool = false) -> Int {
        var changed = 0
        for index in transactions.indices where transactions[index].splits.isEmpty {
            let transaction = transactions[index]
            guard let rule = firstMatch(rules, for: transaction, accountName: transaction.accountID.flatMap { accountNames[$0] }) else { continue }
            if transaction.category == "Uncategorised" || overwrite {
                if transaction.category != rule.category || transaction.subcategory != rule.subcategory {
                    transactions[index].category = rule.category
                    transactions[index].subcategory = rule.subcategory
                    changed += 1
                }
            } else if transaction.category == rule.category, transaction.subcategory == nil, let sub = rule.subcategory {
                transactions[index].subcategory = sub
                changed += 1
            }
        }
        return changed
    }

    /// A rule for payments like this one: its shop name, to the given category.
    public static func rule(from transaction: BankTransaction, category: String, subcategory: String?) -> CategoryRule {
        let shop = Categoriser.merchantKey(transaction.merchant)
        let name = shop.isEmpty ? transaction.merchant : shop.capitalized
        return CategoryRule(name: name, conditions: [.init(.description, .contains, shop.isEmpty ? transaction.merchant : shop)],
                            category: category, subcategory: subcategory)
    }

    /// Payments between the account holders' own accounts: a bank transfer code (OBP online
    /// banking payment, FPO faster payment out, TFR, STO, BP) with one of your names. Built from
    /// the names on your statements, so it isn't a stored rule.
    public static func selfTransferRule(names: [String]) -> CategoryRule? {
        let cleaned = Array(Set(names.map { $0.uppercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
        guard !cleaned.isEmpty else { return nil }
        return CategoryRule(id: UUID(uuidString: "00000000-0000-4000-8000-5e1f7a45f3e0")!, name: "Payments to yourselves",
                            conditions: [.init(.description, .containsAny, "OBP, FPO, FPI, TFR, TRANSFER, STO, BP, BILLPAY, BGC, MOB"),
                                         .init(.description, .containsAny, cleaned.joined(separator: ", "))],
                            category: "Internal transfer", subcategory: "Between accounts", isStarter: true)
    }

    // MARK: Starter rules

    private static func starter(_ name: String, _ words: String, _ category: String, _ subcategory: String?, money: CategoryRule.Operator? = nil, over: String? = nil) -> CategoryRule {
        var conditions: [CategoryRule.Condition] = [.init(.description, .containsAny, words)]
        if let money { conditions.append(.init(.amount, money)) }
        if let over { conditions.append(.init(.amount, .greaterThan, over)) }
        // Stable ids, so the same starter rule is one rule on every device.
        let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", abs(name.hashValueStable))) ?? UUID()
        return CategoryRule(id: id, name: name, conditions: conditions, category: category, subcategory: subcategory, isStarter: true)
    }

    /// The rules a new household starts with: common UK banks' codes and well-known shops.
    public static let starterRules: [CategoryRule] = [
        // Cash first: "ATM CASH ... TESCO" is a cash machine at Tesco, not a grocery shop.
        starter("Cash machines", "ATM, CASH WITHDRAWAL, CASHPOINT, CASH MACHINE, LNK, ATM CASH, CSH", "Cash", "ATM withdrawal", money: .isMoneyOut),
        starter("Cashback", "CASHBACK, CASH BACK", "Cash", "Cashback", money: .isMoneyOut),
        // Money moving between your own accounts and cards is neither spending nor income.
        starter("Credit card repayments", "PAYMENT THANK YOU, PAYMENT RECEIVED, DIRECT DEBIT PAYMENT, PAYMENT THANKYOU", "Card payment", "Credit card repayment", money: .isMoneyIn),
        starter("Card bills paid from the bank", "BARCLAYCARD, AMEX, AMERICAN EXPRESS, CAPITAL ONE, HSBC CARD PYMT, MBNA, CARD PYMT", "Card payment", "Credit card repayment", money: .isMoneyOut),
        starter("Pay", "SALARY, PAYROLL, WAGES", "Income", "Salary", money: .isMoneyIn),
        starter("Interest", "INTEREST, GROSS INTEREST", "Income", "Interest", money: .isMoneyIn),
        starter("Government", "HMRC, DWP, CHILD BENEFIT", "Income", "Benefits", money: .isMoneyIn),
        starter("Supermarkets", "TESCO, SAINSBURYS, ASDA, ALDI, LIDL, WAITROSE, MORRISONS, COSTCO, ICELAND, FARMFOODS, M S SIMPLY FOOD, MARKS SPENCER", "Groceries", "Supermarket", money: .isMoneyOut),
        starter("Convenience stores", "CO OP, COOP, SPAR, ONE STOP, NISA, BUDGENS, LONDIS, COSTCUTTER, CROMWELL STORES", "Groceries", "Convenience store", money: .isMoneyOut),
        starter("Online grocery", "OCADO, AMAZON FRESH, GETIR, GORILLAS", "Groceries", "Online grocery", money: .isMoneyOut),
        starter("Coffee", "COSTA, STARBUCKS, PRET, CAFFE NERO, NERO, GAILS", "Eating out", "Coffee", money: .isMoneyOut),
        starter("Fast food", "MCDONALDS, BURGER KING, KFC, GREGGS, SUBWAY, FIVE GUYS, CHICK FIL", "Eating out", "Fast food", money: .isMoneyOut),
        starter("Takeaways", "DELIVEROO, JUST EAT, UBER EATS, DOMINOS, PAPA JOHNS", "Eating out", "Takeaway", money: .isMoneyOut),
        starter("Restaurants", "NANDOS, WAGAMAMA, PIZZA EXPRESS, FRANCO MANCA, DISHOOM, ZIZZI, RESTAURANT", "Eating out", "Restaurant", money: .isMoneyOut),
        starter("Sweets and bakeries", "BIKANERVALA, BAKERY, PATISSERIE, SWEETS", "Eating out", "Sweets and bakery", money: .isMoneyOut),
        starter("Streaming", "NETFLIX, DISNEY, PRIME VIDEO, NOW TV, YOUTUBE PREMIUM, PARAMOUNT", "Subscriptions", "Streaming", money: .isMoneyOut),
        starter("Music", "SPOTIFY, APPLE MUSIC, AUDIBLE, DEEZER", "Subscriptions", "Music", money: .isMoneyOut),
        starter("Cloud storage", "ICLOUD, GOOGLE STORAGE, DROPBOX", "Subscriptions", "Cloud storage", money: .isMoneyOut),
        starter("In-app purchases", "IAP", "Subscriptions", "Apps and games", money: .isMoneyOut),
        starter("Energy", "BRITISH GAS, OCTOPUS, EDF, EON, OVO, SCOTTISH POWER, BULB", "Bills & utilities", "Energy", money: .isMoneyOut),
        starter("Water", "THAMES WATER, AFFINITY WATER, SOUTH EAST WATER, ANGLIAN WATER", "Bills & utilities", "Water", money: .isMoneyOut),
        starter("Phone", "VODAFONE, EE, O2, THREE, ID MOBILE, GIFFGAFF, SMARTY, LEBARA, LYCAMOBILE, TESCO MOBILE, VOXI", "Bills & utilities", "Phone", money: .isMoneyOut),
        starter("Broadband", "BT, SKY, VIRGIN MEDIA, TALKTALK, PLUSNET, HYPEROPTIC, COMMUNITYFIBRE", "Bills & utilities", "Broadband", money: .isMoneyOut),
        starter("Council tax", "COUNCIL TAX", "Bills & utilities", "Council tax", money: .isMoneyOut),
        starter("TV licence", "TV LICENCE, TV LICENSING", "Bills & utilities", "TV licence", money: .isMoneyOut),
        starter("Insurance", "INSURANCE, AVIVA, DIRECT LINE, ADMIRAL", "Bills & utilities", "Insurance", money: .isMoneyOut),
        starter("Fuel", "SHELL, BP, ESSO, TEXACO, JET, GULF, PETROL", "Transport", "Fuel", money: .isMoneyOut),
        starter("Parking", "PARKING, RINGGO, PAYBYPHONE, JUSTPARK, NCP", "Transport", "Parking", money: .isMoneyOut),
        starter("Public transport", "TFL, LUL, TRAINLINE, LNER, GWR, SOUTH WESTERN, NATIONAL RAIL, OYSTER", "Transport", "Public transport", money: .isMoneyOut),
        starter("Taxis", "UBER, UBERBV, BOLT, ADDISON LEE, FREENOW", "Transport", "Taxi", money: .isMoneyOut),
        starter("Pharmacy", "BOOTS, SUPERDRUG, PHARMACY, LLOYDS PHARMACY", "Health", "Pharmacy", money: .isMoneyOut),
        starter("Fitness", "GYM, PUREGYM, DAVID LLOYD, NUFFIELD, VIRGIN ACTIVE", "Health", "Fitness", money: .isMoneyOut),
        starter("Dental and optical", "DENTAL, DENTIST, SPECSAVERS, VISION EXPRESS, OPTICIANS", "Health", "Dental", money: .isMoneyOut),
        starter("Clothes and shoes", "PRIMARK, ZARA, H M, NEXT, TK MAXX, TKMAXX, UNIQLO, SPORTS DIRECT, JD SPORTS, SPORTING FEET, CLARKS", "Shopping", "Clothes and shoes", money: .isMoneyOut),
        starter("Electronics", "CURRYS, APPLE STORE, ARGOS", "Shopping", "Electronics", money: .isMoneyOut),
        starter("Home and garden", "IKEA, DUNELM, HOMEBASE, B Q, WICKES, SCREWFIX, HOMESENSE, PLANT CENTR, PLANT CENTRE, GARDEN CENTRE", "Shopping", "Home and garden", money: .isMoneyOut),
        starter("Online marketplaces", "AMAZON, AMZN, EBAY, VINTED, ETSY, SHEIN, TEMU", "Shopping", "Online marketplace", money: .isMoneyOut),
        starter("Lottery and betting", "NATIONAL LOTTERY, LOTTO, POSTCODE LOTTERY, BET365, PADDY POWER, WILLIAM HILL, LADBROKES, SKY BET", "Entertainment", "Lottery and betting", money: .isMoneyOut),
        starter("Cinema and theatre", "ODEON, VUE, CINEWORLD, EVERYMAN, PICTUREHOUSE, THEATRE", "Entertainment", "Cinema and theatre", money: .isMoneyOut),
        starter("Tickets", "TICKETMASTER, SEE TICKETS, EVENTBRITE, AXS, DICE", "Entertainment", "Events and tickets", money: .isMoneyOut),
        starter("Hair and beauty", "BARBER, BARBERS, SALON, HAIR, NAILS, BEAUTY", "Personal care", "Hair and beauty", money: .isMoneyOut),
        starter("Charity", "JUSTGIVING, GOFUNDME, OXFAM, BRITISH RED CROSS, CANCER RESEARCH, UNICEF, CHARITY, DONATION", "Gifts & charity", "Charity", money: .isMoneyOut),
        starter("Gifts", "MOONPIG, FUNKY PIGEON, CARD FACTORY, INTERFLORA", "Gifts & charity", "Gifts", money: .isMoneyOut),
        starter("Courses", "UDEMY, COURSERA, LINKEDIN LEARNING, OPEN UNIVERSITY", "Education", "Courses", money: .isMoneyOut),
        starter("Books", "WATERSTONES, WH SMITH, WHSMITH, BLACKWELLS", "Shopping", "Books", money: .isMoneyOut),
        starter("Flights", "EASYJET, RYANAIR, BRITISH AIRWAYS, JET2, WIZZ, EMIRATES", "Travel", "Flights", money: .isMoneyOut),
        starter("Hotels", "AIRBNB, BOOKING COM, PREMIER INN, TRAVELODGE, HOTEL, EXPEDIA", "Travel", "Hotels", money: .isMoneyOut),
        starter("Savings", "NS I, NSI, NS AND I, PREMIUM BONDS, MONEYBOX", "Savings & investments", "Savings", money: .isMoneyOut),
        starter("Investments", "VANGUARD, TRADING 212, NUTMEG, FREETRADE, HARGREAVES LANSDOWN, AJ BELL", "Savings & investments", "Investments", money: .isMoneyOut),
        starter("Rent and mortgage", "RENT, MORTGAGE, LETTINGS", "Housing", nil, money: .isMoneyOut),
        starter("Mortgage lenders", "BIRMINGHAM MIDSHIRES, BHAM MIDSHIRES, HALIFAX MORTGAGE, NATIONWIDE MORTGAGE", "Housing", "Mortgage", money: .isMoneyOut),
        starter("Refunds", "REFUND, REFUNDED", "Income", "Refund", money: .isMoneyIn),
        starter("Bank charges", "CHARGES, OVERDRAFT FEE, ACCOUNT FEE, MONTHLY FEE", "Fees & charges", "Bank charges", money: .isMoneyOut),
        starter("Foreign transaction fees", "NON STERLING, NON STG, FOREIGN TRANSACTION FEE, FX FEE", "Fees & charges", "Foreign transaction fees", money: .isMoneyOut),
        starter("Interest charged", "INTEREST CHARGED, PURCHASE INTEREST, CASH INTEREST", "Fees & charges", "Interest charged", money: .isMoneyOut),
        starter("Moving money to your own accounts", "REVOLUT, MONZO, STARLING, WISE", "Internal transfer", "Between accounts", money: .isMoneyOut),
        starter("Games", "PLAYSTATION, XBOX, STEAM, NINTENDO", "Subscriptions", "Apps and games", money: .isMoneyOut),
        starter("Software and AI", "ANTHROPIC, OPENAI, CHATGPT, MICROSOFT, ADOBE, CANVA", "Subscriptions", "Apps and games", money: .isMoneyOut),
        starter("Memberships", "PATREON, NATIONAL TRUST, ENGLISH HERITAGE", "Subscriptions", "Memberships", money: .isMoneyOut),
        starter("Recipe boxes", "GOUSTO, HELLOFRESH, MINDFUL CHEF", "Groceries", "Online grocery", money: .isMoneyOut),
        starter("Car costs", "DVLA, HALFORDS, KWIK FIT, MOT", "Transport", "Car costs", money: .isMoneyOut),
    ]
}

extension String {
    /// A hash that's the same on every device and every launch (Swift's isn't), for stable ids.
    var hashValueStable: Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash & 0x0000_FFFF_FFFF_FFFF)
    }
}
