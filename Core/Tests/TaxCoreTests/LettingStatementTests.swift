import BudgetCore
import XCTest
@testable import TaxCore

/// All names and figures are made up.
final class LettingStatementTests: XCTestCase {
    static let remittance = """
    SAMPLE LETTINGS
    REMITTANCE ADVICE
    Statement reference : SL_0001
    Rent receipt 20.06.2025 - 19.07.2025 £1,200.00 £1,200.00
    Management fee INV7 £120.00 £24.00 £144.00
    Gas check £60.00
    Total Expenditure £204.00
    Paid £996.00 via Bank Transfer on 23.06.2025
    Rent receipt 20.06.2025 - 19.07.2025 £1,200.00 £1,200.00
    """

    static let management = """
    Sample Lettings Management Statement
    Statement No. 42
    05.05.2025
    Rent received this statement: £1,000.00
    Invoice:
    £96.00Total
    """

    private func payment(_ id: String, _ amount: Decimal, _ day: Int, _ month: Int = 6) -> BankTransaction {
        BankTransaction(date: TaxYear.day(2025, month, day).addingTimeInterval(43_200), merchant: "SAMPLE LETTINGS", amount: amount, fingerprint: id)
    }

    func testReadsARemittanceAdviceAndChecksItAgainstThePayment() throws {
        let statement = try LettingStatementReader.read(texts: [Self.remittance])
        XCTAssertEqual(statement.grossRent, 1_200)
        XCTAssertEqual(statement.fees, 144)
        XCTAssertEqual(statement.repairs, 60)
        XCTAssertEqual(statement.paidToYou, 996)
        XCTAssertEqual(statement.reference, "SL_0001")
        XCTAssertEqual(PropertyLedger.day(statement.date), "23 Jun 2025")
        XCTAssertTrue(statement.isChecked)
        XCTAssertFalse(statement.needsAttention)
    }

    func testReadsFiguresSplitOverLinesAndTwoRentPeriods() throws {
        let text = """
        Remittance
        Advice
        Rent receipt 01.06.2025 – 30.06.2025
        £500.00
        Rent receipt 01.07.2025 – 31.07.2025 £500.00
        Total Expenditure
        £0.00
        Paid £1,000.00 via Bank Transfer on
        02/06/2025
        """
        let statement = try LettingStatementReader.read(texts: [text])
        XCTAssertEqual(statement.grossRent, 1_000)
        XCTAssertEqual(statement.paidToYou, 1_000)
        XCTAssertTrue(statement.isChecked)
    }

    func testFiguresThatDontAddUpNeedAttention() throws {
        let statement = try LettingStatementReader.read(texts: [Self.remittance.replacingOccurrences(of: "£996.00", with: "£990.00")])
        XCTAssertTrue(statement.needsAttention)
        XCTAssertFalse(statement.isChecked)
        XCTAssertTrue(statement.warnings[0].contains("£990.00"))
    }

    func testTheReadingThatChecksOutIsUsed() throws {
        let scrambled = Self.remittance.replacingOccurrences(of: "Total Expenditure £204.00", with: "£204.00 Total Expenditure")
        let statement = try LettingStatementReader.read(texts: [scrambled, Self.remittance])
        XCTAssertTrue(statement.isChecked)
    }

    func testReadsAManagementStatementButSaysItCantBeChecked() throws {
        let statement = try LettingStatementReader.read(texts: [Self.management])
        XCTAssertEqual(statement.grossRent, 1_000)
        XCTAssertEqual(statement.fees, 96)
        XCTAssertEqual(statement.reference, "42")
        XCTAssertEqual(PropertyLedger.day(statement.date), "5 May 2025")
        XCTAssertFalse(statement.isChecked)
        XCTAssertFalse(statement.needsAttention)
        XCTAssertFalse(statement.warnings.isEmpty)
        let without = try LettingStatementReader.read(texts: [Self.management.replacingOccurrences(of: "£96.00Total", with: "")])
        XCTAssertTrue(without.needsAttention)
    }

    func testUnknownOrIncompleteFilesAreRefused() {
        XCTAssertThrowsError(try LettingStatementReader.read(texts: ["Invoice £5.00"])) {
            XCTAssertEqual($0 as? LettingStatementError, .notRecognised)
        }
        XCTAssertThrowsError(try LettingStatementReader.read(texts: ["Remittance Advice\nRent receipt to follow"])) {
            XCTAssertEqual($0 as? LettingStatementError, .missing("rent received"))
        }
    }

    func testReadsTheSpreadsheetLayout() throws {
        let csv = "Property Reference,Gross Rent,Management Fee,Deductions,Net Payment,Date,Description\r\nFlat,\"1,000.00\",100,0,900,05/06/2025,June\r\nFlat,1000,100,50,900,2025-07-05\r\n"
        let found = try LettingStatementReader.read(csv: csv)
        XCTAssertEqual(found.map(\.paidToYou), [900, 850])
        XCTAssertEqual(found.map(\.needsAttention), [false, true])
        XCTAssertEqual(found.map { PropertyLedger.day($0.date) }, ["5 Jun 2025", "5 Jul 2025"])
        XCTAssertEqual(found[0].propertyName, "Flat")
        XCTAssertEqual(try LettingStatementReader.read(csv: csv.replacingOccurrences(of: ",", with: "\t").replacingOccurrences(of: "\"1\t000.00\"", with: "1000")).count, 2)
        XCTAssertThrowsError(try LettingStatementReader.read(csv: "Date,Description,Amount\n05/06/2025,A,5"))
        XCTAssertThrowsError(try LettingStatementReader.read(csv: "Property,Gross Rent,Fee,Deductions,Net,Date\nFlat,1000,0,0,1000,soon"))
    }

    func testImportingLinksTheBankPaymentOnceAndNeverTwice() throws {
        var book = PropertyBook(properties: [RentalProperty(id: "flat", name: "Flat")])
        let statement = try LettingStatementReader.read(texts: [Self.remittance])
        let payments = [payment("far", 996, 1, 8), payment("other", 995, 23), payment("rent", 996, 24)]
        XCTAssertEqual(book.add([statement, statement], propertyID: "flat", payments: payments), 1)
        XCTAssertEqual(book.statements.first?.bankFingerprint, "rent")
        XCTAssertEqual(book.add([statement], propertyID: "flat", payments: payments), 0)
        XCTAssertEqual(book.add([statement], propertyID: "nowhere", payments: payments), 0)
        let ledger = PropertyLedger.build(transactions: payments, book: book, year: TaxYear(startYear: 2025))
        XCTAssertEqual(ledger.lines.filter { $0.category == .rent }.map(\.amount), [1_200])
    }

    func testATypedStatementImportedAgainIsNoticedAndBlocksFiling() throws {
        let found = try LettingStatementReader.read(texts: [Self.remittance])
        let payments = [payment("rent", 996, 20)]
        let typed = AgentStatement(id: "typed", propertyID: "flat", date: TaxYear.day(2025, 6, 20), grossRent: 1_200,
                                   fees: 144, repairs: 60, bankFingerprint: "rent")
        var book = PropertyBook(properties: [RentalProperty(id: "flat", name: "Flat")], statements: [typed])
        XCTAssertFalse(book.has(found, propertyID: "flat"))
        XCTAssertEqual(book.lookalike(of: found, propertyID: "flat", in: payments)?.id, "typed")
        // A second payment of the same amount means it is another statement.
        XCTAssertNil(book.lookalike(of: found, propertyID: "flat", in: payments + [payment("next", 996, 27)]))
        book.add([found], propertyID: "flat", payments: payments)
        let ledger = PropertyLedger.build(transactions: payments, book: book, year: TaxYear(startYear: 2025))
        XCTAssertTrue(ledger.issues.contains { $0.blocksFiling && $0.message.contains("looks the same") })
    }

    func testDocumentsAreToldApartFromBankStatements() {
        XCTAssertEqual(TaxDocument.recognise(Self.remittance), .lettingStatement)
        XCTAssertEqual(TaxDocument.recognise(Self.management), .lettingStatement)
        XCTAssertNil(TaxDocument.recognise("Date Description Paid out Paid in Balance"))
    }
}
