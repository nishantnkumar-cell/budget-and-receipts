import Foundation

enum SubscriptionCategory: String, Codable, CaseIterable, Identifiable {
    case streaming, broadband, cable, mobile, insurance, energy, utilities, software, membership, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BillingPeriod: String, Codable, CaseIterable, Identifiable {
    case weekly, monthly, quarterly, halfYearly, yearly, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .halfYearly: return "Every 6 months"; case .custom: return "Custom"; default: return rawValue.capitalized }
    }
}

enum ContractPricing: String, Codable, CaseIterable, Identifiable {
    case fixed, variable, introductory, unknown
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SubscriptionStatus: String, Codable, CaseIterable, Identifiable {
    case active, paused, cancelled, expired
    var id: String { rawValue }
}

struct SubscriptionContract: Identifiable, Codable, Hashable {
    var id = UUID()
    var vendor: String
    var category: SubscriptionCategory
    var startDate: Date
    var minimumTermEndDate: Date? = nil
    var renewalDate: Date? = nil
    var billingPeriod: BillingPeriod
    var customIntervalDays: Int? = nil
    var nextPaymentDueDate: Date
    var expectedAmount: Decimal
    var currency = "GBP"
    var pricing: ContractPricing = .unknown
    var fixedPriceEndDate: Date? = nil
    var cancellationNoticeDays: Int? = nil
    var accountReference = ""
    var notes = ""
    var status: SubscriptionStatus = .active
    var transactionMatchers: [String] = []
}

struct SubscriptionPayment: Identifiable, Codable, Hashable {
    var id = UUID()
    let subscriptionID: UUID
    let transactionID: String
    let vendor: String
    let date: Date
    let amount: Decimal
}

struct VendorSpendSummary: Identifiable, Hashable {
    var id: String { vendor.lowercased() }
    let vendor: String
    let totalPaid: Decimal
    let paymentCount: Int
    let firstPayment: Date?
    let lastPayment: Date?
    let averagePayment: Decimal
}
