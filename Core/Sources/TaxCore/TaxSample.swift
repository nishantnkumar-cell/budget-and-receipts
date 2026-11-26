import BudgetCore
import Foundation

/// Entirely made-up people, property and money, for sample screens and tests.
public enum TaxSample {
    public static let year = TaxYear(startYear: 2025)

    public static func make() -> (transactions: [BankTransaction], book: PropertyBook) {
        let flat = RentalProperty(id: "flat", name: "12 Sample Street")
        var transactions: [BankTransaction] = []
        var statements: [AgentStatement] = []

        func pay(_ id: String, _ date: Date, _ merchant: String, _ amount: Decimal, _ category: String, tagged: Bool = false) {
            var payment = BankTransaction(date: date, merchant: merchant, amount: amount, category: category, fingerprint: "tax-sample-\(id)")
            if tagged { payment.tags = [PropertyLedger.tag(for: flat)] }
            transactions.append(payment)
        }

        for index in 0..<12 {
            let month = (index + 3) % 12 + 1
            let calendarYear = month >= 4 ? 2025 : 2026
            let date = TaxYear.day(calendarYear, month, 10)
            let statement = AgentStatement(id: "statement-\(index)", propertyID: flat.id, date: date, grossRent: 2_400, fees: 288,
                                           repairs: index == 4 ? 180 : 0, bankFingerprint: "tax-sample-rent-\(index)")
            statements.append(statement)
            pay("rent-\(index)", date, "EXAMPLE LETTINGS", statement.net, "Income")
            pay("mortgage-\(index)", TaxYear.day(calendarYear, month, 7), "SAMPLE BANK MORTGAGE", -1_150, "Housing")
        }
        pay("insurance", TaxYear.day(2025, 5, 2), "PRETEND LANDLORD INSURANCE", -320, "Bills & utilities")
        pay("ground", TaxYear.day(2025, 7, 1), "SAMPLE FREEHOLDS GROUND RENT", -250, "Housing")
        pay("plumber", TaxYear.day(2025, 11, 20), "A PLUMBER", -450, "Housing", tagged: true)
        pay("kitchen", TaxYear.day(2025, 9, 14), "PRETEND KITCHENS", -6_500, "Housing", tagged: true)
        // Left without a category on purpose, to show how something to review appears.
        pay("hardware", TaxYear.day(2026, 1, 8), "CORNER HARDWARE", -64, "Shopping", tagged: true)

        let book = PropertyBook(
            properties: [flat],
            rules: [
                PropertyRule(merchantContains: "SAMPLE BANK MORTGAGE", propertyID: flat.id, category: .mortgagePayment, added: 3),
                PropertyRule(merchantContains: "GROUND RENT", propertyID: flat.id, category: .ratesAndInsurance, added: 2),
                PropertyRule(merchantContains: "LANDLORD INSURANCE", propertyID: flat.id, category: .ratesAndInsurance, added: 1)
            ],
            assignments: [
                TaxAssignment(fingerprint: "tax-sample-plumber", propertyID: flat.id, category: .repairs, paymentDate: TaxYear.day(2025, 11, 20)),
                TaxAssignment(fingerprint: "tax-sample-kitchen", propertyID: flat.id, category: .capital, paymentDate: TaxYear.day(2025, 9, 14))
            ],
            statements: statements,
            interest: [MortgageInterest(propertyID: flat.id, taxYear: year.description, interestAndFees: 9_600)],
            pay: [
                TaxPay(id: "job-me", person: .me, taxYear: year.description, employer: "Made-up Umbrella Ltd",
                       taxablePay: 150_000, taxDeducted: 53_703),
                TaxPay(id: "job-partner", person: .partner, taxYear: year.description, employer: "Imaginary Employer plc",
                       taxablePay: 95_000, taxDeducted: 25_432, isShared: true)
            ])
        return (transactions, book)
    }
}
