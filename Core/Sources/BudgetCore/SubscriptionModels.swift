import Foundation

public enum SubscriptionCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case streaming, broadband, cable, mobile, insurance, energy, utilities, software, membership, other
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum BillingPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case weekly, monthly, quarterly, halfYearly, yearly, custom
    public var id: String { rawValue }
    public var title: String {
        switch self { case .halfYearly: return "Every 6 months"; case .custom: return "Custom"; default: return rawValue.capitalized }
    }
}

public enum ContractPricing: String, Codable, CaseIterable, Identifiable, Sendable {
    case fixed, variable, introductory, unknown
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum SubscriptionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case active, paused, cancelled, expired
    public var id: String { rawValue }
}

public struct SubscriptionContract: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var vendor: String
    public var category: SubscriptionCategory
    public var startDate: Date
    public var minimumTermEndDate: Date? = nil
    public var renewalDate: Date? = nil
    public var billingPeriod: BillingPeriod
    public var customIntervalDays: Int? = nil
    public var nextPaymentDueDate: Date
    public var expectedAmount: Decimal
    public var currency = "GBP"
    public var pricing: ContractPricing = .unknown
    public var fixedPriceEndDate: Date? = nil
    public var cancellationNoticeDays: Int? = nil
    public var accountReference = ""
    public var notes = ""
    public var status: SubscriptionStatus = .active
    public var transactionMatchers: [String] = []
    /// Hidden from a partner the household is shared with.
    public var isPrivate: Bool? = nil

    public init(
        id: UUID = UUID(),
        vendor: String,
        category: SubscriptionCategory,
        startDate: Date,
        minimumTermEndDate: Date? = nil,
        renewalDate: Date? = nil,
        billingPeriod: BillingPeriod,
        customIntervalDays: Int? = nil,
        nextPaymentDueDate: Date,
        expectedAmount: Decimal,
        currency: String = "GBP",
        pricing: ContractPricing = .unknown,
        fixedPriceEndDate: Date? = nil,
        cancellationNoticeDays: Int? = nil,
        accountReference: String = "",
        notes: String = "",
        status: SubscriptionStatus = .active,
        transactionMatchers: [String] = []
    ) {
        self.id = id
        self.vendor = vendor
        self.category = category
        self.startDate = startDate
        self.minimumTermEndDate = minimumTermEndDate
        self.renewalDate = renewalDate
        self.billingPeriod = billingPeriod
        self.customIntervalDays = customIntervalDays
        self.nextPaymentDueDate = nextPaymentDueDate
        self.expectedAmount = expectedAmount
        self.currency = currency
        self.pricing = pricing
        self.fixedPriceEndDate = fixedPriceEndDate
        self.cancellationNoticeDays = cancellationNoticeDays
        self.accountReference = accountReference
        self.notes = notes
        self.status = status
        self.transactionMatchers = transactionMatchers
    }
}

public struct SubscriptionPayment: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public let subscriptionID: UUID
    public let transactionID: String
    public let vendor: String
    public let date: Date
    public let amount: Decimal

    public init(id: UUID = UUID(), subscriptionID: UUID, transactionID: String, vendor: String, date: Date, amount: Decimal) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.transactionID = transactionID
        self.vendor = vendor
        self.date = date
        self.amount = amount
    }
}

public struct VendorSpendSummary: Identifiable, Hashable, Sendable {
    public var id: String { vendor.lowercased() }
    public let vendor: String
    public let totalPaid: Decimal
    public let paymentCount: Int
    public let firstPayment: Date?
    public let lastPayment: Date?
    public let averagePayment: Decimal

    public init(vendor: String, totalPaid: Decimal, paymentCount: Int, firstPayment: Date?, lastPayment: Date?, averagePayment: Decimal) {
        self.vendor = vendor
        self.totalPaid = totalPaid
        self.paymentCount = paymentCount
        self.firstPayment = firstPayment
        self.lastPayment = lastPayment
        self.averagePayment = averagePayment
    }
}
