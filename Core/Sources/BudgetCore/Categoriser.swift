import Foundation

/// A suggested category and why it was picked.
public struct CategorySuggestion: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        /// You put this merchant or item in this category before.
        case learned
        /// A built-in list of well-known shops and items.
        case keyword
        /// Apple Intelligence on the device, or an Apple Maps lookup, for an unknown merchant.
        case lookedUp
        /// One of your rules (or a starter rule).
        case rule
    }

    public let category: String
    public var subcategory: String? = nil
    /// 0 to 1. Learned suggestions use how often you chose this category.
    public let confidence: Double
    public let source: Source

    public init(category: String, confidence: Double, source: Source) {
        self.category = category
        self.confidence = confidence
        self.source = source
    }
}

/// Suggests categories for bank transactions and receipt items, on the device.
/// It learns from the categories you already chose and falls back to a built-in list
/// of well-known UK shops. What you chose before always wins over the built-in list.
public struct Categoriser: Sendable {
    private var merchantVotes: [String: [String: Int]] = [:]
    private var itemVotes: [String: [String: Int]] = [:]
    private var lookedUp: [String: MerchantCategory] = [:]
    private var rules: [CategoryRule] = []
    private var accountNames: [UUID: String] = [:]

    /// Learns from transactions you have already categorised, including approved receipt splits.
    /// `lookedUp` holds categories found for unknown merchants; your own choices still win.
    public init(history: [BankTransaction] = [], lookedUp: [String: MerchantCategory] = [:], rules: [CategoryRule] = [], accountNames: [UUID: String] = [:]) {
        self.lookedUp = lookedUp
        self.rules = rules
        self.accountNames = accountNames
        for transaction in history {
            if transaction.splits.isEmpty {
                guard transaction.category != "Uncategorised" else { continue }
                merchantVotes[Self.merchantKey(transaction.merchant), default: [:]][transaction.category, default: 0] += 1
            } else {
                for split in transaction.splits where split.category != "Uncategorised" {
                    itemVotes[Self.itemKey(split.label), default: [:]][split.category, default: 0] += 1
                }
            }
        }
        merchantVotes[""] = nil
        itemVotes[""] = nil
    }

    // MARK: Suggestions

    public func suggest(for transaction: BankTransaction) -> CategorySuggestion? {
        // Your own rules decide first, then what you chose for this shop before, then the
        // starter rules: a choice you made yourself always beats a built-in guess.
        let accountName = transaction.accountID.flatMap { accountNames[$0] }
        func ruleSuggestion(_ rules: [CategoryRule]) -> CategorySuggestion? {
            guard let rule = RulesEngine.firstMatch(rules, for: transaction, accountName: accountName) else { return nil }
            var suggestion = CategorySuggestion(category: rule.category, confidence: 1, source: .rule)
            suggestion.subcategory = rule.subcategory
            return suggestion
        }
        if let own = ruleSuggestion(rules.filter { !$0.isStarter }) { return own }
        if let learned = Self.best(merchantVotes[Self.merchantKey(transaction.merchant)]) { return learned }
        if let starter = ruleSuggestion(rules.filter(\.isStarter)) { return starter }
        let words = Self.words(transaction.merchant + " " + transaction.description)
        if transaction.amount > 0 {
            if let income = Self.match(words, Self.incomeKeywords) { return CategorySuggestion(category: income, confidence: 0.6, source: .keyword) }
            // A credit card's statement thanks you for the payment from your bank account.
            if Self.match(words, Self.cardRepaymentKeywords) != nil { return CategorySuggestion(category: "Card payment", confidence: 0.7, source: .keyword) }
            // "CR" marks money in on bank statements; a sizeable one from a company is pay.
            if words.first == "CR", transaction.amount >= 200 { return CategorySuggestion(category: "Income", confidence: 0.5, source: .keyword) }
            return nil
        }
        if let keyword = Self.match(words, Self.merchantKeywords) {
            return CategorySuggestion(category: keyword, confidence: 0.6, source: .keyword)
        }
        return lookedUp[Self.merchantKey(transaction.merchant)].map { CategorySuggestion(category: $0.category, confidence: 0.5, source: .lookedUp) }
    }

    /// Item suggestions use what you called similar items before, then common grocery and
    /// chemist words, then the shop: an item from a supermarket is most likely groceries.
    public func suggest(forItem description: String, merchant: String = "") -> CategorySuggestion? {
        if let learned = Self.best(itemVotes[Self.itemKey(description)]) { return learned }
        if let keyword = Self.match(Self.words(description), Self.itemKeywords) {
            return CategorySuggestion(category: keyword, confidence: 0.6, source: .keyword)
        }
        guard !merchant.isEmpty else { return nil }
        let shop = suggest(for: BankTransaction(date: Date(), merchant: merchant, amount: -1, fingerprint: ""))
        return shop.map { CategorySuggestion(category: $0.category, confidence: $0.confidence * 0.5, source: $0.source) }
    }

    /// Fills in the category of uncategorised transactions. Categories you set stay as they are.
    public func categorise(_ transactions: [BankTransaction]) -> [BankTransaction] {
        transactions.map { transaction in
            guard transaction.splits.isEmpty, let suggestion = suggest(for: transaction) else { return transaction }
            var categorised = transaction
            if transaction.category == "Uncategorised" {
                categorised.category = suggestion.category
                categorised.subcategory = suggestion.subcategory
            } else if transaction.subcategory == nil, suggestion.category == transaction.category, let sub = suggestion.subcategory {
                // Already in the right category: a rule can still say where in it.
                categorised.subcategory = sub
            }
            return categorised
        }
    }

    /// Fills in uncategorised receipt items.
    public func categorise(_ editor: inout ReceiptDraftEditor) {
        for index in editor.items.indices where editor.items[index].category == "Uncategorised" {
            if let suggestion = suggest(forItem: editor.items[index].description, merchant: editor.merchant) {
                editor.items[index].category = suggestion.category
            }
        }
    }

    // MARK: Keys

    /// A stable key for a merchant: statement noise such as card references, store numbers
    /// and town names after the shop name is dropped. "TESCO STORES 3297 LONDON" → "TESCO STORES".
    public static func merchantKey(_ merchant: String) -> String {
        let noise: Set<String> = ["CARD", "PAYMENT", "TO", "POS", "CONTACTLESS", "PURCHASE", "DEBIT", "VISA", "DD", "SO", "FPO", "BGC", "ON", "AT"]
        let kept = words(merchant).filter { !noise.contains($0) && !$0.contains(where: \.isNumber) }
        return kept.prefix(2).joined(separator: " ")
    }

    static func itemKey(_ description: String) -> String {
        words(description).filter { !$0.contains(where: \.isNumber) && $0.count > 1 }.joined(separator: " ")
    }

    /// Upper-case words with punctuation removed, accents folded. "Sainsbury's" → "SAINSBURYS".
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .uppercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func best(_ votes: [String: Int]?) -> CategorySuggestion? {
        guard let votes, let top = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        let total = votes.values.reduce(0, +)
        return CategorySuggestion(category: top.key, confidence: Double(top.value) / Double(total), source: .learned)
    }

    /// The category of the first keyword (one or more whole words) found in the text.
    private static func match(_ words: [String], _ table: [(String, [String])]) -> String? {
        let text = " " + words.joined(separator: " ") + " "
        for (category, keywords) in table where keywords.contains(where: { text.contains(" \($0) ") }) {
            return category
        }
        return nil
    }

    // MARK: Built-in lists

    static let incomeKeywords: [(String, [String])] = [
        ("Income", ["SALARY", "PAYROLL", "WAGES", "HMRC", "DIVIDEND", "INTEREST", "PENSION"])
    ]

    static let cardRepaymentKeywords: [(String, [String])] = [
        ("Card payment", ["PAYMENT THANK YOU", "PAYMENT RECEIVED", "DIRECT DEBIT PAYMENT", "PAYMENT THANKYOU"])
    ]

    static let merchantKeywords: [(String, [String])] = [
        ("Groceries", ["TESCO", "SAINSBURYS", "ASDA", "ALDI", "LIDL", "WAITROSE", "MORRISONS", "CO OP", "COOP", "OCADO", "ICELAND", "M S SIMPLY FOOD", "SPAR"]),
        ("Eating out", ["PRET", "COSTA", "STARBUCKS", "MCDONALDS", "GREGGS", "NANDOS", "DELIVEROO", "JUST EAT", "UBER EATS", "WAGAMAMA", "KFC", "PIZZA", "CAFE", "RESTAURANT"]),
        ("Subscriptions", ["NETFLIX", "SPOTIFY", "DISNEY", "APPLE COM BILL", "PRIME VIDEO", "YOUTUBE", "AUDIBLE", "ICLOUD"]),
        ("Transport", ["UBER", "TFL", "TRAINLINE", "LNER", "GWR", "SHELL", "BP", "ESSO", "TEXACO", "PARKING", "RINGGO", "BOLT"]),
        ("Bills & utilities", ["BRITISH GAS", "OCTOPUS", "EDF", "EON", "OVO", "THAMES WATER", "COUNCIL TAX", "VODAFONE", "EE", "O2", "THREE", "VIRGIN MEDIA", "SKY", "BT", "TV LICENCE", "TV LICENSING", "ID MOBILE", "GIFFGAFF", "SMARTY", "TALKTALK", "PLUSNET", "LEBARA", "LYCAMOBILE", "TESCO MOBILE", "HYPEROPTIC", "COMMUNITYFIBRE"]),
        ("Housing", ["RENT", "MORTGAGE", "LETTINGS"]),
        ("Health", ["BOOTS", "SUPERDRUG", "PHARMACY", "DENTAL", "DENTIST", "OPTICIANS", "SPECSAVERS", "GYM", "PUREGYM"]),
        ("Shopping", ["AMAZON", "AMZN", "ARGOS", "IKEA", "JOHN LEWIS", "PRIMARK", "NEXT", "EBAY", "CURRYS", "ZARA", "H M", "TK MAXX", "TKMAXX", "TJ MAXX", "HOMESENSE", "DUNELM", "B Q", "HOMEBASE", "WILKO", "POUNDLAND", "HOME BARGAINS", "SPORTS DIRECT", "DECATHLON", "GARDEN CENTRE", "PLANT CENTR", "PLANT CENTRE", "VINTED", "ETSY", "SHEIN", "TEMU"]),
        ("Travel", ["AIRBNB", "BOOKING COM", "EASYJET", "RYANAIR", "BRITISH AIRWAYS", "JET2", "PREMIER INN", "HOTEL", "EXPEDIA"]),
        ("Savings & investments", ["VANGUARD", "TRADING 212", "MONEYBOX", "ISA", "NUTMEG", "FREETRADE", "NS I", "NSI", "PREMIUM BONDS", "HARGREAVES LANSDOWN", "AJ BELL"])
    ]

    static let itemKeywords: [(String, [String])] = [
        ("Groceries", ["MILK", "BREAD", "EGGS", "BUTTER", "CHEESE", "BANANAS", "APPLES", "TOMATOES", "POTATOES", "ONIONS", "CHICKEN", "BEEF", "PASTA", "RICE", "YOGHURT", "YOGURT", "CEREAL", "FRUIT", "VEG", "COFFEE", "TEA", "JUICE", "WATER"]),
        ("Health", ["SHAMPOO", "CONDITIONER", "TOOTHPASTE", "PARACETAMOL", "IBUPROFEN", "PLASTERS", "VITAMINS", "DEODORANT", "SOAP"]),
        ("Shopping", ["BATTERIES", "SOCKS", "CHARGER", "CABLE", "BULB"]),
        ("Family", ["NAPPIES", "WIPES", "TOYS", "BIRTHDAY CARD", "GIFT"])
    ]
}
