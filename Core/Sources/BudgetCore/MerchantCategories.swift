import Foundation

/// Categories learned for merchants the built-in list doesn't know, from Apple Intelligence
/// on the device or an Apple Maps lookup. Kept so each merchant is only looked up once.
public struct MerchantCategory: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        case ai
        case maps
    }

    public var category: String
    public var source: Source

    public init(category: String, source: Source) {
        self.category = category
        self.source = source
    }
}

public enum MerchantCategories {
    /// Apple Maps point-of-interest kinds (MKPointOfInterestCategory raw values) and the
    /// spending category each one means. Kinds not listed give no suggestion.
    public static let mapsCategories: [String: String] = [
        "MKPOICategoryRestaurant": "Eating out", "MKPOICategoryCafe": "Eating out",
        "MKPOICategoryBakery": "Eating out", "MKPOICategoryBrewery": "Eating out",
        "MKPOICategoryWinery": "Eating out", "MKPOICategoryNightlife": "Eating out",
        "MKPOICategoryFoodMarket": "Groceries",
        "MKPOICategoryPharmacy": "Health", "MKPOICategoryHospital": "Health",
        "MKPOICategoryFitnessCenter": "Health", "MKPOICategoryDentist": "Health",
        "MKPOICategoryGasStation": "Transport", "MKPOICategoryEVCharger": "Transport",
        "MKPOICategoryParking": "Transport", "MKPOICategoryPublicTransport": "Transport",
        "MKPOICategoryCarRental": "Transport", "MKPOICategoryAutomotiveRepair": "Transport",
        "MKPOICategoryAirport": "Travel", "MKPOICategoryHotel": "Travel",
        "MKPOICategoryStore": "Shopping", "MKPOICategoryLaundry": "Shopping",
        "MKPOICategoryBeauty": "Shopping",
        "MKPOICategoryMovieTheater": "Shopping", "MKPOICategoryMuseum": "Family",
        "MKPOICategoryAmusementPark": "Family", "MKPOICategoryZoo": "Family",
        "MKPOICategoryAquarium": "Family", "MKPOICategoryPark": "Family",
        "MKPOICategorySchool": "Family", "MKPOICategoryUniversity": "Family",
        "MKPOICategoryBank": "Bills & utilities", "MKPOICategoryPostOffice": "Bills & utilities",
    ]

    /// A category from an AI answer, only if it is one of ours and a real choice.
    public static func validated(_ answer: String?) -> String? {
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let named = FinanceCategories.all.first { $0.caseInsensitiveCompare(answer) == .orderedSame }
            ?? CategoryCatalog.builtIn.first { $0.id.caseInsensitiveCompare(answer) == .orderedSame }.map { FinanceCategories.resolve($0.id) }
        let match = named.flatMap { FinanceCategories.all.contains($0) ? $0 : nil }
        guard let match, match != "Uncategorised", !BudgetCalculator.transferCategories.contains(match) else { return nil }
        return match
    }

    /// The words worth searching for a merchant: card wording and reference numbers dropped,
    /// up to five words kept ("CARD PAYMENT TO SADDA SUPERSTORE LTD HOUNSLOW 1234" →
    /// "SADDA SUPERSTORE LTD HOUNSLOW").
    /// A bank transfer or standing order, whose description is usually a person's name.
    /// Such lines are never looked up online.
    public static func isPersonTransfer(_ merchant: String) -> Bool {
        let codes: Set<String> = ["FPO", "FPI", "OBP", "TFR", "TRANSFER", "STO", "SO", "BGC", "MOB", "BACS", "CHAPS"]
        guard let first = Categoriser.words(merchant).first else { return false }
        return codes.contains(first)
    }

    public static func searchText(_ merchant: String) -> String {
        let noise: Set<String> = ["CARD", "PAYMENT", "TO", "POS", "CONTACTLESS", "PURCHASE", "DEBIT", "VISA", "VIS", "DD", "SO", "BP", "CD", "TRANSACTION", "GB", "GBR", "UK", "ENG", "IAP"]
        let words = Categoriser.words(merchant).filter { !noise.contains($0) && !$0.contains(where: \.isNumber) }
        return words.prefix(5).joined(separator: " ")
    }

    /// Merchants among these transactions that still need a category and aren't known yet.
    public static func unknownMerchants(_ transactions: [BankTransaction], known: [String: MerchantCategory], categoriser: Categoriser) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for transaction in transactions where transaction.category == "Uncategorised" && transaction.splits.isEmpty && transaction.amount < 0 {
            let key = Categoriser.merchantKey(transaction.merchant)
            guard !key.isEmpty, known[key] == nil, categoriser.suggest(for: transaction) == nil, seen.insert(key).inserted else { continue }
            result.append(transaction.merchant)
        }
        return result
    }
}
