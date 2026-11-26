import BudgetCore
import Foundation

/// What a payment means for a property. The UK property page (SA105) box is in the comment.
public enum PropertyCategory: String, Codable, CaseIterable, Sendable {
    case rent                 // 20
    case otherIncome          // 20
    case ratesAndInsurance    // 24
    case repairs              // 25
    case professionalFees     // 27
    case services             // 28
    case otherExpense         // 29
    case replacementItems     // 36
    case financeCost          // 44
    /// A repayment mortgage payment: part interest, part capital. Never counted directly;
    /// the lender's yearly interest figure is used instead.
    case mortgagePayment
    /// Buying or improving: not an expense against rent.
    case capital
    case ignore

    public var isIncome: Bool { self == .rent || self == .otherIncome }
    public var isCounted: Bool { self != .mortgagePayment && self != .capital && self != .ignore }

    public var title: String {
        switch self {
        case .rent: "Rent"
        case .otherIncome: "Other property income"
        case .ratesAndInsurance: "Rates, insurance, ground rent"
        case .repairs: "Repairs and maintenance"
        case .professionalFees: "Agent, legal and professional fees"
        case .services: "Services provided"
        case .otherExpense: "Other expenses"
        case .replacementItems: "Replacing domestic items"
        case .financeCost: "Mortgage interest and finance costs"
        case .mortgagePayment: "Mortgage payment"
        case .capital: "Buying or improving"
        case .ignore: "Not for tax"
        }
    }
}

public struct RentalProperty: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Tag a payment "Property: <name>" to attach it to this property.
    public var name: String
    /// My share of income and costs, 0 to 1. The rest is my spouse's.
    public var myShare: Decimal
    /// True once HMRC has a Form 17 for an unequal split of a jointly owned property.
    public var form17: Bool

    public init(id: String = UUID().uuidString, name: String, myShare: Decimal = Decimal(1) / 2, form17: Bool = false) {
        self.id = id
        self.name = name
        self.myShare = myShare
        self.form17 = form17
    }

    public func share(of person: Person) -> Decimal { person == .me ? myShare : 1 - myShare }
}

/// "Payments to this shop or person are this kind of cost for this property."
public struct PropertyRule: Codable, Hashable, Sendable, Identifiable {
    public var merchantContains: String
    public var propertyID: String
    public var category: PropertyCategory
    /// When it was made, in seconds. A newer rule is tried before an older one.
    public var added: Double
    /// Made from a payment kept from the partner, so the shop's name stays private too.
    public var isPrivate: Bool

    public var id: String { merchantContains.lowercased() }

    public init(merchantContains: String, propertyID: String, category: PropertyCategory,
                added: Double = 0, isPrivate: Bool = false) {
        self.merchantContains = merchantContains
        self.propertyID = propertyID
        self.category = category
        self.added = added
        self.isPrivate = isPrivate
    }

    public func matches(_ payment: BankTransaction) -> Bool {
        !merchantContains.isEmpty && payment.merchant.localizedCaseInsensitiveContains(merchantContains)
    }
}

/// A choice made by hand for one payment, or for one part of a split payment. It beats rules
/// and tags.
public struct TaxAssignment: Codable, Hashable, Sendable, Identifiable {
    public var fingerprint: String
    /// The part of a split payment. Nil for the whole payment.
    public var splitID: UUID?
    public var propertyID: String
    public var category: PropertyCategory
    /// The payment's date, so a payment that later disappears is noticed in the right year.
    public var paymentDate: Date?

    public var id: String { splitID.map { "\(fingerprint)#\($0.uuidString)" } ?? fingerprint }

    public init(fingerprint: String, splitID: UUID? = nil, propertyID: String, category: PropertyCategory, paymentDate: Date? = nil) {
        self.fingerprint = fingerprint
        self.splitID = splitID
        self.propertyID = propertyID
        self.category = category
        self.paymentDate = paymentDate
    }
}

/// A letting agent's statement: the gross rent and what the agent kept back.
public struct AgentStatement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var propertyID: String
    public var date: Date
    public var grossRent: Decimal
    public var fees: Decimal
    public var repairs: Decimal
    public var otherExpense: Decimal
    /// The bank payment this explains. That payment is then not counted a second time.
    public var bankFingerprint: String?

    public init(id: String = UUID().uuidString, propertyID: String, date: Date, grossRent: Decimal, fees: Decimal = 0,
                repairs: Decimal = 0, otherExpense: Decimal = 0, bankFingerprint: String? = nil) {
        self.id = id
        self.propertyID = propertyID
        self.date = date
        self.grossRent = grossRent
        self.fees = fees
        self.repairs = repairs
        self.otherExpense = otherExpense
        self.bankFingerprint = bankFingerprint
    }

    public var net: Decimal { grossRent - fees - repairs - otherExpense }
}

/// The lender's yearly figure for interest and finance charges.
public struct MortgageInterest: Codable, Hashable, Sendable, Identifiable {
    public var propertyID: String
    public var taxYear: String
    public var interestAndFees: Decimal

    public var id: String { "\(propertyID)|\(taxYear)" }

    public init(propertyID: String, taxYear: String, interestAndFees: Decimal) {
        self.propertyID = propertyID
        self.taxYear = taxYear
        self.interestAndFees = interestAndFees
    }
}

/// One P60 (or the year's final payslip).
public struct TaxPay: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var person: Person
    public var taxYear: String
    public var employer: String
    public var taxablePay: Decimal
    public var taxDeducted: Decimal
    /// Pension paid from take-home pay ("relief at source"), including the basic-rate relief.
    /// Salary sacrifice and net-pay pensions are already taken out of taxable pay: leave them out.
    public var reliefAtSourcePension: Decimal
    /// Pay is private unless you choose to show your partner.
    public var isShared: Bool

    public init(id: String = UUID().uuidString, person: Person, taxYear: String, employer: String,
                taxablePay: Decimal, taxDeducted: Decimal, reliefAtSourcePension: Decimal = 0, isShared: Bool = false) {
        self.id = id
        self.person = person
        self.taxYear = taxYear
        self.employer = employer
        self.taxablePay = taxablePay
        self.taxDeducted = taxDeducted
        self.reliefAtSourcePension = reliefAtSourcePension
        self.isShared = isShared
    }
}

/// Amounts from last year's return that carry into this one.
public struct CarriedForward: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var person: Person
    public var taxYear: String
    public var losses: Decimal
    public var financeCosts: Decimal
    public var isShared: Bool

    public init(id: String = UUID().uuidString, person: Person, taxYear: String, losses: Decimal = 0,
                financeCosts: Decimal = 0, isShared: Bool = false) {
        self.id = id
        self.person = person
        self.taxYear = taxYear
        self.losses = losses
        self.financeCosts = financeCosts
        self.isShared = isShared
    }
}

/// Everything entered for tax. The payments themselves are the budget's own and only read.
public struct PropertyBook: Hashable, Sendable {
    public var properties: [RentalProperty]
    public var rules: [PropertyRule]
    public var assignments: [TaxAssignment]
    public var statements: [AgentStatement]
    public var interest: [MortgageInterest]
    public var pay: [TaxPay]
    public var carried: [CarriedForward]

    public init(properties: [RentalProperty] = [], rules: [PropertyRule] = [], assignments: [TaxAssignment] = [],
                statements: [AgentStatement] = [], interest: [MortgageInterest] = [],
                pay: [TaxPay] = [], carried: [CarriedForward] = []) {
        self.properties = properties
        self.rules = rules
        self.assignments = assignments
        self.statements = statements
        self.interest = interest
        self.pay = pay
        self.carried = carried
    }
}
