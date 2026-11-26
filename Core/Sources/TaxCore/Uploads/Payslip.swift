import BudgetCore
import Foundation

/// What an umbrella company payslip says that a tax return needs: the figures to date.
public struct Payslip: Hashable, Sendable {
    public var payDate: Date
    /// Taxable pay and income tax so far in the tax year.
    public var taxablePayToDate: Decimal?
    public var taxToDate: Decimal?
    /// This payslip's own figures, used to check the reading.
    public var taxablePay: Decimal?
    public var tax: Decimal?
    public var netPay: Decimal?
    /// True when the figures agree with each other.
    public var isChecked: Bool
    public var warnings: [String]
}

public enum PayslipError: Error, Equatable, Sendable {
    case notRecognised
    case missingDate

    public var explanation: String {
        switch self {
        case .notRecognised:
            "This isn't a payslip layout the app knows: one showing “Total Taxable Pay”, “PAYE Net Pay” and figures to date. Nothing was imported; use Add Pay instead."
        case .missingDate: "The pay date couldn't be found. Nothing was imported; use Add Pay instead."
        }
    }
}

public enum PayslipReader {
    /// Reads a payslip from its text. Pass each way of taking the text out of the file; the
    /// reading that checks out best is used.
    public static func read(texts: [String]) throws -> Payslip {
        var best: Payslip?
        var failure = PayslipError.notRecognised
        func score(_ slip: Payslip) -> Int {
            (slip.isChecked ? 100 : 0) + (slip.taxablePayToDate == nil ? 0 : 10) + (slip.taxToDate == nil ? 0 : 10) - slip.warnings.count
        }
        for text in texts {
            do {
                let found = try read(text: text)
                if best.map({ score(found) > score($0) }) ?? true { best = found }
            } catch let error as PayslipError {
                if error != .notRecognised { failure = error }
            }
        }
        if let best { return best }
        throw failure
    }

    static func read(text original: String) throws -> Payslip {
        // Runs of spaces become one, so a label reads the same however the file spaces it.
        let text = original.replacingOccurrences(of: #"[ \t\u00A0]+"#, with: " ", options: .regularExpression)
        guard TaxDocument.recognise(text) == .payslip else { throw PayslipError.notRecognised }
        let date = UploadText.date
        let dated = UploadText.first(#"Pay\s*Date\s*/\s*Tax\s*Period\s*:?\s*"# + date, in: text)
            ?? UploadText.first(#"Pay\s*Date[^\d]{0,60}?"# + date, in: text)
        guard let payDate = dated.flatMap({ UploadText.day($0.groups[0]) }) else { throw PayslipError.missingDate }

        func amounts(_ label: String) -> [Decimal] {
            UploadText.all(label + #"\s*:?\s*"# + UploadText.amount, in: text).compactMap { UploadText.money($0.groups[0]) }
        }
        let taxablePay = amounts(#"Total\s+Taxable\s+Pay"#).first
        let deductions = amounts(#"Total\s+Deductions"#).first
        let netPay = amounts(#"PAYE\s+Net\s+Pay"#).first
        // Figures to date can't be smaller than this payslip's, so which is which doesn't
        // depend on the order the file lists them in.
        let hasToDate = UploadText.first(#"To\s+Date\s+Figures"#, in: text) != nil
        let payToDate = hasToDate ? amounts(#"(?<!Total\s)Taxable\s+Pay"#).max() : nil
        // "Income Tax" is printed for this payslip and again to date.
        let taxes = amounts(#"Income\s+Tax"#)
        let taxToDate = hasToDate && taxes.count > 1 ? taxes.max() : nil
        let tax = taxes.count > 1 ? taxes.min() : taxes.first

        var warnings: [String] = []
        if payToDate == nil || taxToDate == nil { warnings.append("The figures to date couldn't all be found. Type them from the payslip.") }
        var agrees = payToDate != nil && taxToDate != nil
        if let taxablePay, let deductions, let netPay {
            if taxablePay - deductions != netPay {
                agrees = false
                warnings.append("Taxable pay less deductions doesn't equal the net pay. Check the figures.")
            }
        } else {
            agrees = false
            warnings.append("This payslip's own totals couldn't all be found to check the reading.")
        }
        if let payToDate, let taxablePay, payToDate < taxablePay {
            agrees = false
            warnings.append("Taxable pay to date is less than this payslip's. Check it.")
        }
        if let taxToDate, let tax, taxToDate < tax {
            agrees = false
            warnings.append("Tax to date is less than this payslip's. Check it.")
        }
        if let payToDate, let taxToDate, taxToDate >= payToDate {
            agrees = false
            warnings.append("Tax to date isn't less than pay to date. Check both.")
        }
        return Payslip(payDate: payDate, taxablePayToDate: payToDate, taxToDate: taxToDate, taxablePay: taxablePay, tax: tax,
                       netPay: netPay, isChecked: agrees, warnings: warnings)
    }
}

extension TaxYear {
    /// The supported tax year a day falls in.
    public static func containing(_ date: Date) -> TaxYear? { supported.first { $0.contains(date) } }
}

extension PropertyBook {
    /// The pay entry a payslip would update: your own entry for that person, year and employer.
    public func pay(for person: Person, year: TaxYear, employer: String) -> TaxPay? {
        let name = employer.trimmingCharacters(in: .whitespaces)
        return pay.first {
            $0.person == person && $0.taxYear == year.description
                && $0.employer.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Records a payslip's figures to date as the year's pay from that employer. The latest
    /// payslip wins. Nothing changes, and false comes back, when a later one is already
    /// recorded or your partner typed the entry in.
    @discardableResult
    public mutating func record(payslipDated payDate: Date, taxablePay: Decimal, taxDeducted: Decimal,
                                person: Person, employer: String) -> Bool {
        let name = employer.trimmingCharacters(in: .whitespaces)
        guard let year = TaxYear.containing(payDate), !name.isEmpty else { return false }
        if var current = self.pay(for: person, year: year, employer: name) {
            guard current.enteredBy == .me, current.payslipDate.map({ $0 <= payDate }) ?? true else { return false }
            current.taxablePay = taxablePay
            current.taxDeducted = taxDeducted
            current.payslipDate = payDate
            if let index = pay.firstIndex(where: { $0.id == current.id }) { pay[index] = current }
        } else {
            // The same on every device, so two imports make one entry.
            var entry = TaxPay(id: "payslip|\(person.rawValue)|\(year)|\(name.lowercased())", person: person, taxYear: year.description,
                               employer: name, taxablePay: taxablePay, taxDeducted: taxDeducted)
            entry.payslipDate = payDate
            pay.removeAll { $0.id == entry.id }
            pay.append(entry)
        }
        return true
    }
}
