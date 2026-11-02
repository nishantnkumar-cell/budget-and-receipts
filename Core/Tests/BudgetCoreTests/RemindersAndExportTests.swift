import XCTest
@testable import BudgetCore

final class ReminderPlannerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func contract(_ configure: (inout SubscriptionContract) -> Void = { _ in }) -> SubscriptionContract {
        var contract = SubscriptionContract(vendor: "Octopus", category: .energy, startDate: day(1, 1), billingPeriod: .monthly, nextPaymentDueDate: day(11, 20), expectedAmount: money("85.00"))
        configure(&contract)
        return contract
    }

    func testPaymentReminderTwoDaysBeforeAtNine() {
        let reminders = ReminderPlanner(calendar: calendar).reminders(for: contract(), now: day(11, 1))
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders[0].kind, .paymentDue)
        XCTAssertEqual(reminders[0].fireDate, day(11, 18, hour: 9))
        XCTAssertTrue(reminders[0].body.contains("£85.00"))
    }

    func testPastRemindersAreDropped() {
        XCTAssertTrue(ReminderPlanner(calendar: calendar).reminders(for: contract(), now: day(11, 19)).isEmpty)
    }

    func testCancellationDeadlineUsesNoticePeriod() {
        let reminders = ReminderPlanner(calendar: calendar).reminders(for: contract {
            $0.renewalDate = day(12, 31)
            $0.cancellationNoticeDays = 30
        }, now: day(11, 1))
        let deadline = reminders.first { $0.kind == .cancellationDeadline }
        XCTAssertEqual(deadline?.eventDate, day(12, 1))
        XCTAssertEqual(deadline?.fireDate, day(11, 24, hour: 9))
        XCTAssertNotNil(reminders.first { $0.kind == .renewal })
    }

    func testFixedPriceEndOnlyForFixedPricing() {
        let planner = ReminderPlanner(calendar: calendar)
        let variable = planner.reminders(for: contract { $0.fixedPriceEndDate = day(12, 31); $0.pricing = .variable }, now: day(11, 1))
        XCTAssertNil(variable.first { $0.kind == .fixedPriceEnds })
        let fixed = planner.reminders(for: contract { $0.fixedPriceEndDate = day(12, 31); $0.pricing = .fixed }, now: day(11, 1))
        XCTAssertEqual(fixed.first { $0.kind == .fixedPriceEnds }?.fireDate, day(12, 17, hour: 9))
    }

    func testCancelledContractsHaveNoReminders() {
        XCTAssertTrue(ReminderPlanner(calendar: calendar).reminders(for: [contract { $0.status = .cancelled }], now: day(11, 1)).isEmpty)
    }

    func testIdentifierIsStablePerContractAndKind() {
        let c = contract()
        let first = ReminderPlanner(calendar: calendar).reminders(for: c, now: day(11, 1))
        let second = ReminderPlanner(calendar: calendar).reminders(for: c, now: day(11, 2))
        XCTAssertEqual(first.map(\.identifier), second.map(\.identifier))
    }
}

final class CSVExportTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }

    func testPlainAndSplitRows() {
        let plain = BankTransaction(date: date(1), merchant: "SALARY, ACME", amount: money("2500.00"), category: "Income", fingerprint: "a")
        let split = BankTransaction(date: date(3), merchant: "TESCO", amount: money("-40.00"), category: "Groceries", fingerprint: "b", splits: [
            TransactionSplit(label: "Food", category: "Groceries", amount: money("30.00")),
            TransactionSplit(label: "Socks", category: "Shopping", amount: money("10.00"))
        ])
        let csv = CSVExporter.transactions([split, plain], calendar: calendar)
        XCTAssertEqual(csv, """
        Date,Merchant,Description,Category,Amount,Split of\r
        2026-10-01,"SALARY, ACME",,Income,2500,\r
        2026-10-03,Food,,Groceries,-30,TESCO\r
        2026-10-03,Socks,,Shopping,-10,TESCO\r

        """)
    }

    func testFormulaInjectionIsNeutralised() {
        XCTAssertEqual(CSVExporter.escape("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(CSVExporter.escape("-12.5"), "-12.5", "Negative amounts stay numbers")
        XCTAssertEqual(CSVExporter.escape("-cmd"), "'-cmd")
    }

    func testExportCanBeImportedAgain() throws {
        let original = [BankTransaction(date: date(5), merchant: "COSTA", description: "COSTA", amount: money("-3.20"), category: "Eating out", fingerprint: "c")]
        let csv = CSVExporter.transactions(original, calendar: calendar)
        let mapping = try XCTUnwrap(CSVColumnMapping.guess(header: CSVReader.firstRecord(csv)))
        let rows = try StatementImporter.parseCSV(csv, mapping: mapping, timeZone: calendar.timeZone)
        XCTAssertEqual(rows.map(\.amount), [money("-3.20")])
        XCTAssertEqual(calendar.component(.day, from: rows[0].date), 5)
    }
}

final class BudgetRolloverTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func day(_ month: Int, _ d: Int = 10) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: 12))! }

    private func spend(_ month: Int, _ amount: String) -> BankTransaction {
        BankTransaction(date: day(month), merchant: "Shop", amount: money(amount), category: "Groceries", fingerprint: UUID().uuidString)
    }

    func testLeftoverRollsIntoNextMonth() {
        let budgets = [MonthlyBudget(category: "Groceries", limit: money("300"), month: day(9, 1), rollover: true)]
        let calculator = BudgetCalculator(calendar: calendar)
        // September: spent 250 of 300, so October has 300 + 50.
        XCTAssertEqual(calculator.effectiveLimit(for: "Groceries", transactions: [spend(9, "-250")], budgets: budgets, month: day(10)), money("350"))
        // October overspent 400 of 350, so November has 300 - 50.
        XCTAssertEqual(calculator.effectiveLimit(for: "Groceries", transactions: [spend(9, "-250"), spend(10, "-400")], budgets: budgets, month: day(11)), money("250"))
    }

    func testWithoutRolloverLimitIsFixed() {
        let budgets = [MonthlyBudget(category: "Groceries", limit: money("300"), month: day(9, 1))]
        XCTAssertEqual(BudgetCalculator(calendar: calendar).effectiveLimit(for: "Groceries", transactions: [spend(9, "-100")], budgets: budgets, month: day(10)), money("300"))
    }

    func testOldBudgetsWithoutRolloverStillDecode() throws {
        let json = #"[{"id":"7C8B2E1A-0000-4000-8000-000000000001","category":"Groceries","limit":300,"month":0}]"#
        let budgets = try JSONDecoder().decode([MonthlyBudget].self, from: Data(json.utf8))
        XCTAssertNil(budgets[0].rollover)
    }
}
