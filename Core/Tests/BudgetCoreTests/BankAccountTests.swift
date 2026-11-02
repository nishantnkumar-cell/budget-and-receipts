import XCTest
@testable import BudgetCore

final class BankAccountTests: XCTestCase {
    private let current = BankAccount(name: "Current", number: "12345678", cardEndings: ["4321"])
    private let credit = BankAccount(name: "Credit card", number: "5555 6666 7777 8888")

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }

    func testLabelsShowOnlyTheLastFourDigits() {
        XCTAssertEqual(current.label, "Current ••5678")
        XCTAssertEqual(BankAccount(name: "Cash").label, "Cash")
    }

    func testRecognisesAccountsFromNumbersAndReceipts() {
        let accounts = [current, credit]
        XCTAssertEqual(BankAccounts.account(forNumber: "XXXX8888", in: accounts)?.id, credit.id)
        XCTAssertNil(BankAccounts.account(forNumber: "", in: accounts))
        XCTAssertEqual(BankAccounts.cardEnding(in: "VISA DEBIT\n************4321\nAUTH 123456"), "4321")
        XCTAssertEqual(BankAccounts.cardEnding(in: "Card: XXXX XXXX XXXX 8888"), "8888")
        XCTAssertNil(BankAccounts.cardEnding(in: "TOTAL 12.34 on 1234"))
        XCTAssertEqual(BankAccounts.account(forReceiptText: "MASTERCARD **** 4321", in: accounts)?.id, current.id)
    }

    func testOFXAccountNumberIsRead() throws {
        let ofx = "<OFX><BANKACCTFROM><ACCTID>12345678\n</BANKACCTFROM><STMTTRN><DTPOSTED>20261003\n<TRNAMT>-4.50\n<FITID>A1\n<NAME>COSTA\n</STMTTRN></OFX>"
        XCTAssertEqual(try StatementImporter.parseOFX(ofx, timeZone: calendar.timeZone).first?.accountNumber, "12345678")
    }

    func testCSVAccountColumnIsRead() throws {
        let csv = "Date,Account,Description,Amount\r\n03/10/2026,12345678,COSTA,-4.50\r\n"
        let mapping = try XCTUnwrap(CSVColumnMapping.guess(header: CSVReader.firstRecord(csv)))
        XCTAssertEqual(mapping.account, 1)
        XCTAssertEqual(try StatementImporter.parseCSV(csv, mapping: mapping, timeZone: calendar.timeZone).first?.accountNumber, "12345678")
    }

    func testImportTagsTheAccountAndKeepsSamePaymentInTwoAccounts() {
        let row = StatementRow(date: day(3), description: "COSTA", amount: money("-4.50"))
        let first = StatementImporter.prepare([row], existing: [], account: current.id, calendar: calendar)
        XCTAssertEqual(first.newTransactions.first?.accountID, current.id)
        // The same coffee bought with the credit card the same day is a different payment.
        let second = StatementImporter.prepare([row], existing: first.newTransactions, account: credit.id, calendar: calendar)
        XCTAssertEqual(second.newTransactions.count, 1)
        // Importing the current account file again adds nothing.
        XCTAssertTrue(StatementImporter.prepare([row], existing: first.newTransactions, account: current.id, calendar: calendar).newTransactions.isEmpty)
    }

    func testLinesImportedBeforeAccountsAreStillDuplicates() {
        let row = StatementRow(date: day(3), description: "COSTA", amount: money("-4.50"))
        let old = StatementImporter.prepare([row], existing: [], calendar: calendar).newTransactions
        XCTAssertNil(old.first?.accountID)
        XCTAssertTrue(StatementImporter.prepare([row], existing: old, account: current.id, calendar: calendar).newTransactions.isEmpty)
    }

    func testRowNumberWinsOverTheChosenAccount() {
        let row = StatementRow(date: day(3), description: "COSTA", amount: money("-4.50"), accountNumber: "8888")
        let result = StatementImporter.prepare([row], existing: [], account: current.id, accountForNumber: { BankAccounts.account(forNumber: $0, in: [self.current, self.credit])?.id }, calendar: calendar)
        XCTAssertEqual(result.newTransactions.first?.accountID, credit.id)
    }

    func testSpendingByAccount() {
        var a = BankTransaction(date: day(3), merchant: "TESCO", amount: money("-20.00"), category: "Groceries", fingerprint: "a")
        a.accountID = current.id
        var b = BankTransaction(date: day(4), merchant: "AMAZON", amount: money("-15.00"), category: "Shopping", fingerprint: "b")
        b.accountID = credit.id
        let c = BankTransaction(date: day(5), merchant: "CASH", amount: money("-5.00"), category: "Eating out", fingerprint: "c")
        let salary = BankTransaction(date: day(1), merchant: "ACME", amount: money("2000.00"), category: "Income", fingerprint: "d")
        let totals = BankAccounts.spendingByAccount([a, b, c, salary], month: day(1), calculator: BudgetCalculator(calendar: calendar))
        XCTAssertEqual(totals[current.id], money("20.00"))
        XCTAssertEqual(totals[credit.id], money("15.00"))
        XCTAssertEqual(totals[nil], money("5.00"))
    }

    func testReceiptCardPicksTheRightAccountsPayment() {
        let pending = PendingReceipt(editor: ReceiptDraftEditor(merchant: "SHOP", purchaseDate: day(5), receiptTotal: money("3.20")))
        var fromCurrent = BankTransaction(date: day(5), merchant: "PRET", amount: money("-3.20"), fingerprint: "p")
        fromCurrent.accountID = current.id
        var fromCredit = BankTransaction(date: day(5), merchant: "COSTA", amount: money("-3.20"), fingerprint: "c")
        fromCredit.accountID = credit.id
        let pairs = ReceiptMatcher.autoMatch([pending], in: [fromCurrent, fromCredit], accountFor: { _ in self.credit.id }, calendar: calendar)
        XCTAssertEqual(pairs.first?.transaction, "c")
        // Without the card, two equal payments are too close to call.
        XCTAssertTrue(ReceiptMatcher.autoMatch([pending], in: [fromCurrent, fromCredit], calendar: calendar).isEmpty)
    }

    func testOtherAccountsPaymentIsNeverMatched() {
        let pending = PendingReceipt(editor: ReceiptDraftEditor(merchant: "PRET", purchaseDate: day(5), receiptTotal: money("3.20")))
        var fromCurrent = BankTransaction(date: day(5), merchant: "PRET", amount: money("-3.20"), fingerprint: "p")
        fromCurrent.accountID = current.id
        XCTAssertTrue(ReceiptMatcher.autoMatch([pending], in: [fromCurrent], accountFor: { _ in self.credit.id }, calendar: calendar).isEmpty)
    }
}
