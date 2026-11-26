import BudgetCore
import Foundation

/// Turns the budget's payments and the property book into one year's figures per property,
/// counting everything once and saying what still needs a person to look at it.
public struct PropertyLedger: Sendable {
    public struct Line: Hashable, Sendable {
        public var propertyID: String
        public var date: Date?
        public var source: String
        public var category: PropertyCategory
        /// Positive for income received and for a cost paid.
        public var amount: Decimal
    }

    public struct Issue: Hashable, Sendable {
        public var message: String
        /// True when the figures can't be trusted until this is sorted out.
        public var blocksFiling: Bool

        public init(message: String, blocksFiling: Bool) {
            self.message = message
            self.blocksFiling = blocksFiling
        }
    }

    public var lines: [Line] = []
    public var issues: [Issue] = []

    public func total(_ propertyID: String, _ category: PropertyCategory) -> Decimal {
        lines.filter { $0.propertyID == propertyID && $0.category == category }.reduce(0) { $0 + $1.amount }
    }

    /// Hand choices whose payment is no longer in the budget.
    public static func lostAssignments(transactions: [BankTransaction], book: PropertyBook) -> [TaxAssignment] {
        let present = Dictionary(transactions.map { ($0.fingerprint, Set($0.splits.map(\.id))) }, uniquingKeysWith: { first, _ in first })
        return book.assignments.filter { assignment in
            guard let parts = present[assignment.fingerprint] else { return true }
            return assignment.splitID.map { !parts.contains($0) } ?? false
        }
    }

    public static func tag(for property: RentalProperty) -> String { "Property: \(property.name)" }

    static func name(_ statement: AgentStatement) -> String { "Agent statement of \(day(statement.date))" }

    public static func build(transactions: [BankTransaction], book: PropertyBook, year: TaxYear, asOf: Date = Date()) -> PropertyLedger {
        var ledger = PropertyLedger()
        let properties = Dictionary(book.properties.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func block(_ message: String) { ledger.issues.append(Issue(message: message, blocksFiling: true)) }
        func note(_ message: String) { ledger.issues.append(Issue(message: message, blocksFiling: false)) }

        if properties.count != book.properties.count { block("Two properties have the same id.") }
        for property in book.properties {
            if property.myShare < 0 || property.myShare > 1 {
                block("\(property.name): the ownership share must be between 0 and 1.")
            }
            let joint = property.myShare > 0 && property.myShare < 1
            if joint && property.myShare != Decimal(string: "0.5")! && !property.form17 {
                block("\(property.name): a married couple's joint property is taxed 50/50 unless HMRC has a Form 17.")
            }
        }

        // Agent statements first: they explain bank payments that must not be counted again.
        var explained = Set<String>()
        var statementIDs = Set<String>()
        let byFingerprint = Dictionary(transactions.map { ($0.fingerprint, $0) }, uniquingKeysWith: { first, _ in first })
        for statement in book.statements {
            guard statementIDs.insert(statement.id).inserted else {
                block("\(name(statement)) is entered twice.")
                continue
            }
            // A linked payment is spoken for even if the statement falls in another tax year.
            if let fingerprint = statement.bankFingerprint, !explained.insert(fingerprint).inserted {
                block("Two agent statements point to the same bank payment (\(day(statement.date))).")
            }
            guard year.contains(statement.date) else { continue }
            guard properties[statement.propertyID] != nil else {
                block("\(name(statement)) names an unknown property.")
                continue
            }
            if let fingerprint = statement.bankFingerprint {
                if let payment = byFingerprint[fingerprint] {
                    if payment.amount != statement.net {
                        block("\(name(statement)) pays out \(TaxMoney.format(statement.net)), but the bank shows \(TaxMoney.format(payment.amount)).")
                    }
                } else {
                    block("\(name(statement)): its bank payment is no longer there.")
                }
            } else {
                note("\(name(statement)) isn't linked to a bank payment. Check that payment isn't counted too.")
            }
            let parts: [(PropertyCategory, Decimal)] = [
                (.rent, statement.grossRent), (.professionalFees, statement.fees),
                (.repairs, statement.repairs), (.otherExpense, statement.otherExpense)
            ]
            for (category, amount) in parts where amount != 0 {
                ledger.lines.append(Line(propertyID: statement.propertyID, date: statement.date,
                                         source: name(statement), category: category, amount: amount))
            }
        }

        let certified = Set(book.interest.filter { $0.taxYear == year.description }.map(\.propertyID))
        let assignments = PaymentClassifier.index(book.assignments)
        var seen = Set<String>()

        for payment in transactions.sorted(by: { ($0.date, $0.fingerprint) < ($1.date, $1.fingerprint) }) {
            guard year.contains(payment.date), seen.insert(payment.fingerprint).inserted,
                  !explained.contains(payment.fingerprint) else { continue }
            let label = "\(payment.merchant) (\(TaxMoney.format(payment.amount)))"
            /// Property, kind and the amount as money in (positive) or out (negative).
            var chosen: [(propertyID: String, category: PropertyCategory, amount: Decimal)] = []
            switch PaymentClassifier.classify(payment, book: book, assignments: assignments) {
            case .notProperty:
                continue
            case .needsReview(let reason):
                block("\(label) \(reason)")
                continue
            case .assigned(let propertyID, let category, _):
                chosen = [(propertyID, category, payment.amount)]
            case .parts(let parts):
                // Parts are held as sizes; the payment says which way the money went.
                chosen = parts.map { ($0.propertyID, $0.category, payment.amount < 0 ? -$0.split.amount : $0.split.amount) }
            }
            if chosen.contains(where: { $0.category.isCounted }) {
                if let currency = payment.loggedCurrency, currency.uppercased() != "GBP" {
                    block("\(label) was logged in \(currency) and has no statement line yet.")
                    continue
                }
                if payment.reimbursement != nil {
                    note("\(label) is marked as being paid back. The full amount is counted.")
                }
            }
            for item in chosen {
                guard properties[item.propertyID] != nil else {
                    block("\(label) points to an unknown property.")
                    continue
                }
                if item.category == .financeCost && certified.contains(item.propertyID) {
                    note("\(label) is left out: the lender's yearly figure already covers finance costs.")
                    continue
                }
                let amount = item.category.isIncome ? item.amount : -item.amount
                ledger.lines.append(Line(propertyID: item.propertyID, date: payment.date,
                                         source: payment.merchant, category: item.category, amount: amount))
            }
        }

        // A choice whose payment (or part) has gone would otherwise drop out silently.
        for assignment in book.assignments where assignment.category != .ignore {
            guard let date = assignment.paymentDate, year.contains(date) else { continue }
            if let payment = byFingerprint[assignment.fingerprint] {
                if let part = assignment.splitID, !payment.splits.contains(where: { $0.id == part }) {
                    block("\(payment.merchant) on \(day(date)): its split changed. Choose the parts again.")
                }
            } else {
                block("A payment you marked on \(day(date)) is no longer there. Mark its replacement and forget the old one.")
            }
        }

        // An unlinked statement and a bank receipt for rent in the same month look like one
        // payment counted twice.
        for statement in book.statements where statement.bankFingerprint == nil && year.contains(statement.date) {
            let month = TaxYear.calendar.component(.month, from: statement.date)
            let clash = ledger.lines.contains {
                $0.propertyID == statement.propertyID && $0.category == .rent
                    && !$0.source.hasPrefix("Agent statement of ")
                    && $0.date.map { TaxYear.calendar.component(.month, from: $0) == month } == true
            }
            if clash {
                block("\(name(statement)) isn't linked, and rent from the bank is counted in the same month. Link them.")
            }
        }

        var certificates = Set<String>()
        for certificate in book.interest where certificate.taxYear == year.description {
            guard properties[certificate.propertyID] != nil else {
                block("A mortgage interest figure names an unknown property.")
                continue
            }
            guard certificates.insert(certificate.propertyID).inserted else {
                block("Two mortgage interest figures for the same property and year.")
                continue
            }
            ledger.lines.append(Line(propertyID: certificate.propertyID, date: nil, source: "Lender's yearly figure",
                                     category: .financeCost, amount: certificate.interestAndFees))
        }

        for property in book.properties {
            let mine = ledger.lines.filter { $0.propertyID == property.id }
            if mine.contains(where: { $0.category == .mortgagePayment }) && !certified.contains(property.id) {
                block("\(property.name): enter the lender's \(year) interest figure. Mortgage payments aren't counted.")
            }
            let months = Set(mine.filter { $0.category == .rent }.compactMap(\.date).map {
                TaxYear.calendar.component(.month, from: $0)
            })
            if asOf >= year.end && !mine.isEmpty && months.count < 12 {
                note("\(property.name): rent appears in \(months.count) of 12 months. Check for empty months or missing statements.")
            }
        }
        for person in [Person.me, .partner] {
            let jobs = book.pay.filter { $0.person == person && $0.taxYear == year.description }
            if Set(jobs.map { "\($0.taxablePay)|\($0.taxDeducted)" }).count < jobs.count {
                note("The same pay is entered twice for \(person == .me ? "you" : "your spouse") in \(year). Remove one.")
            }
        }
        if !book.properties.isEmpty {
            ledger.issues += coverage(transactions: transactions, year: year, asOf: asOf)
            for (person, name) in [(Person.me, "you"), (Person.partner, "your spouse")]
            where !book.pay.contains(where: { $0.person == person && $0.taxYear == year.description }) {
                note("No pay is entered for \(name) in \(year). If there was a job, add the P60: it changes the tax rate.")
            }
        }
        return ledger
    }

    /// Whether the payment history reaches across the tax year. Judged on all accounts
    /// together, so one account with a later start isn't noticed.
    static func coverage(transactions: [BankTransaction], year: TaxYear, asOf: Date) -> [Issue] {
        let dates = transactions.map(\.date)
        func problem(_ message: String) -> [Issue] { [Issue(message: message, blocksFiling: true)] }
        guard dates.contains(where: year.contains), let first = dates.min(), let last = dates.max() else {
            return problem("There are no payments in \(year). Import that year's statements.")
        }
        var issues: [Issue] = []
        let week: TimeInterval = 7 * 86_400
        if first > year.start.addingTimeInterval(week) {
            issues += problem("Your payments start on \(day(first)), after \(year) began. Import statements from \(day(year.start)).")
        }
        if asOf >= year.end && last < year.end.addingTimeInterval(-5 * week) {
            issues += problem("Your payments stop on \(day(last)), before \(year) ended. Import the later statements.")
        }
        return issues
    }

    public static func day(_ date: Date) -> String {
        let parts = TaxYear.calendar.dateComponents([.day, .month, .year], from: date)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(parts.day!) \(months[parts.month! - 1]) \(parts.year!)"
    }
}
