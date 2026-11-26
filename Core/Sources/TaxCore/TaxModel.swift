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
    /// My share of income and costs, 0 to 1. The rest is my spouse's. 1 or 0 means the
    /// property is in one name only.
    public var myShare: Decimal
    /// The date on the Form 17 sent to HMRC for an unequal split of a jointly owned property.
    /// It only applies to income from that date.
    public var form17From: Date?

    public init(id: String = UUID().uuidString, name: String, myShare: Decimal = Decimal(1) / 2, form17From: Date? = nil) {
        self.id = id
        self.name = name
        self.myShare = myShare
        self.form17From = form17From
    }

    /// Owned together in unequal shares, which a married couple is only taxed on with a Form 17.
    public var isUnequalJoint: Bool { myShare > 0 && myShare < 1 && myShare != Decimal(1) / 2 }

    /// The share taxed on a person for money on a date. Without a date (a yearly figure), the
    /// year's shares weighted by days.
    public func share(of person: Person, on date: Date?, in year: TaxYear) -> Decimal {
        var mine = myShare
        if isUnequalJoint {
            let half = Decimal(1) / 2
            if let from = form17From {
                if let date {
                    mine = date < from ? half : myShare
                } else {
                    let length = year.end.timeIntervalSince(year.start)
                    let before = min(max(from.timeIntervalSince(year.start), 0), length)
                    let days = Decimal(Int((length / 86_400).rounded()))
                    let daysBefore = Decimal(Int((before / 86_400).rounded(.down)))
                    mine = (half * daysBefore + myShare * (days - daysBefore)) / days
                }
            } else {
                mine = half
            }
        }
        return person == .me ? mine : 1 - mine
    }
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

    /// A private rule and a shared one for the same shop are two different items.
    public var id: String { (isPrivate ? "private|" : "") + merchantContains.lowercased() }

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
    /// Who typed it in. Only they can change it.
    public var enteredBy: Person

    public init(id: String = UUID().uuidString, person: Person, taxYear: String, employer: String,
                taxablePay: Decimal, taxDeducted: Decimal, reliefAtSourcePension: Decimal = 0, isShared: Bool = false,
                enteredBy: Person = .me) {
        self.enteredBy = enteredBy
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

/// One person's other figures for a year: amounts from last year's return, advance payments
/// already made, and Gift Aid.
public struct YearFigures: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var person: Person
    public var taxYear: String
    /// Property losses brought forward.
    public var losses: Decimal
    /// Unused residential finance costs brought forward.
    public var financeCosts: Decimal
    /// Payments on account already made towards this year's bill.
    public var advancePaid: Decimal
    /// Gift Aid donations including the basic-rate tax added by the charity.
    public var giftAid: Decimal
    public var isShared: Bool
    public var enteredBy: Person

    public init(id: String = UUID().uuidString, person: Person, taxYear: String, losses: Decimal = 0,
                financeCosts: Decimal = 0, advancePaid: Decimal = 0, giftAid: Decimal = 0, isShared: Bool = false,
                enteredBy: Person = .me) {
        self.id = id
        self.person = person
        self.taxYear = taxYear
        self.losses = losses
        self.financeCosts = financeCosts
        self.advancePaid = advancePaid
        self.giftAid = giftAid
        self.isShared = isShared
        self.enteredBy = enteredBy
    }

    public var isBlank: Bool { losses == 0 && financeCosts == 0 && advancePaid == 0 && giftAid == 0 }
}

/// Everything entered for tax. The payments themselves are the budget's own and only read.
public struct PropertyBook: Hashable, Sendable {
    public var properties: [RentalProperty]
    public var rules: [PropertyRule]
    public var assignments: [TaxAssignment]
    public var statements: [AgentStatement]
    public var interest: [MortgageInterest]
    public var pay: [TaxPay]
    public var figures: [YearFigures]

    public init(properties: [RentalProperty] = [], rules: [PropertyRule] = [], assignments: [TaxAssignment] = [],
                statements: [AgentStatement] = [], interest: [MortgageInterest] = [],
                pay: [TaxPay] = [], figures: [YearFigures] = []) {
        self.properties = properties
        self.rules = rules
        self.assignments = assignments
        self.statements = statements
        self.interest = interest
        self.pay = pay
        self.figures = figures
    }
}
