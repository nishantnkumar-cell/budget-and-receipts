import XCTest
@testable import BudgetCore

final class ReimbursementTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    private func day(_ d: Int, _ m: Int = 10) -> Date { calendar.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12))! }

    func testFullyReimbursedPaymentIsNotSpending() {
        var lunch = BankTransaction(date: day(3), merchant: "Client lunch", amount: -money("48.20"), category: "Eating out", fingerprint: "a")
        lunch.reimbursement = Reimbursement(from: "Work", amount: money("48.20"))
        let coffee = BankTransaction(date: day(4), merchant: "Coffee", amount: -money("3.10"), category: "Eating out", fingerprint: "b")
        let calculator = BudgetCalculator(calendar: calendar)
        XCTAssertEqual(calculator.spendingByCategory([lunch, coffee], month: day(1))["Eating out"], money("3.10"))
    }

    func testPartlyReimbursedSplitPaymentKeepsYourPartToThePenny() {
        var shop = BankTransaction(date: day(3), merchant: "Shop", amount: -money("30.00"), fingerprint: "a")
        shop.splits = [TransactionSplit(label: "Food", category: "Groceries", amount: money("20.00")),
                       TransactionSplit(label: "Cable", category: "Shopping", amount: money("10.00"))]
        shop.reimbursement = Reimbursement(from: "Sam", amount: money("10.00"))
        let totals = BudgetCalculator(calendar: calendar).spendingByCategory([shop], month: day(1))
        XCTAssertEqual(totals["Groceries"], money("13.33"))
        XCTAssertEqual(totals["Shopping"], money("6.67"))
        XCTAssertEqual(totals.values.reduce(0, +), money("20.00"))
    }

    func testRepaymentCreditIsNotIncome() {
        var trainFare = BankTransaction(date: day(3), merchant: "Trainline", amount: -money("62.00"), category: "Transport", fingerprint: "a")
        trainFare.reimbursement = Reimbursement(from: "Work", amount: money("62.00"))
        var back = BankTransaction(date: day(20), merchant: "ACME LTD EXPENSES", amount: money("62.00"), category: "Income", fingerprint: "b")
        let salary = BankTransaction(date: day(25), merchant: "ACME LTD", amount: money("2000.00"), category: "Income", fingerprint: "c")
        XCTAssertEqual(Reimbursements.candidates(for: trainFare, in: [trainFare, back, salary]).map(\.id), ["b"])
        back.repays = trainFare.id
        let report = BudgetCalculator(calendar: calendar).report([trainFare, back, salary], budgets: [], month: day(1))
        XCTAssertEqual(report.income, money("2000.00"))
        XCTAssertEqual(report.spending, 0)
    }

    func testOutstandingTotalsByPayer() {
        var a = BankTransaction(date: day(3), merchant: "Hotel", amount: -money("120.00"), fingerprint: "a")
        a.reimbursement = Reimbursement(from: "Work", amount: money("120.00"))
        var b = BankTransaction(date: day(4), merchant: "Taxi", amount: -money("15.50"), fingerprint: "b")
        b.reimbursement = Reimbursement(from: "Work", amount: money("15.50"))
        var c = BankTransaction(date: day(5), merchant: "Dinner", amount: -money("80.00"), fingerprint: "c")
        c.reimbursement = Reimbursement(from: "Sam", amount: money("40.00"), receivedOn: day(9))
        let owed = Reimbursements.owedBack([a, b, c])
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed.first?.from, "Work")
        XCTAssertEqual(owed.first?.amount, money("135.50"))
    }

    func testPartnerViewScalesTheReimbursementWithTheShare() {
        var dinner = BankTransaction(date: day(3), merchant: "Dinner", amount: -money("100.00"), category: "Eating out", fingerprint: "a", owner: .shared)
        dinner.reimbursement = Reimbursement(from: "Friends", amount: money("50.00"))
        let ledger = CoupleLedger(settings: CoupleSettings(partnerName: "Sam"), calculator: BudgetCalculator(calendar: calendar))
        let mine = ledger.transactions([dinner], for: .me)
        XCTAssertEqual(BudgetCalculator(calendar: calendar).spendingByCategory(mine, month: day(1))["Eating out"], money("25.00"))
    }
}

final class TripTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()
    private func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 8, day: d, hour: 12))! }

    func testReadsForeignAmountsFromStatementText() {
        XCTAssertEqual(ForeignAmountReader.read("CAFE DE FLORE PARIS EUR 42.50 @ 1.1622", home: "GBP"), ForeignAmount(amount: money("42.50"), currency: "EUR"))
        XCTAssertEqual(ForeignAmountReader.read("AMAZON.COM 12.99 USD", home: "GBP")?.currency, "USD")
        XCTAssertEqual(ForeignAmountReader.read("SHOP 1,250.00 CHF incl fee 2.10", home: "GBP"), ForeignAmount(amount: money("1250.00"), currency: "CHF", fee: money("2.10")))
        XCTAssertNil(ForeignAmountReader.read("TESCO STORES 3291", home: "GBP"))
        XCTAssertNil(ForeignAmountReader.read("Coffee GBP 3.10", home: "GBP"))
    }

    func testRateLeavesTheFeeOut() {
        XCTAssertEqual(ForeignAmount(amount: money("116.22"), currency: "EUR", fee: money("2.00")).rate(homeAmount: -money("102.00")), money("1.1622"))
    }

    func testTripTotalsFeesAndRate() {
        let trip = Trip(name: "Lisbon", start: day(10), end: day(14), currency: "EUR", budget: money("500.00"))
        var dinner = BankTransaction(date: day(11), merchant: "Restaurant", amount: -money("50.00"), category: "Eating out", fingerprint: "a")
        dinner.foreign = ForeignAmount(amount: money("58.11"), currency: "EUR")
        let fee = BankTransaction(date: day(11), merchant: "NON-STERLING TRANSACTION FEE", amount: -money("1.38"), category: "Fees & charges", fingerprint: "b")
        var flights = BankTransaction(date: day(1), merchant: "TAP", amount: -money("180.00"), category: "Travel", fingerprint: "c")
        flights.tripID = trip.id
        let homeShop = BankTransaction(date: day(12), merchant: "Tesco", amount: -money("20.00"), category: "Groceries", fingerprint: "d")
        let summary = TripLedger.summary(for: trip, in: [dinner, fee, flights, homeShop], calendar: calendar)
        XCTAssertEqual(Set(summary.payments.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(summary.total, money("231.38"))
        XCTAssertEqual(summary.fees, money("1.38"))
        XCTAssertEqual(summary.foreignTotal, money("58.11"))
        XCTAssertEqual(summary.averageRate, money("1.1622"))
        XCTAssertEqual(summary.days, 5)
        XCTAssertEqual(summary.left, money("268.62"))
        XCTAssertEqual(TripLedger.suggestions(for: trip, in: [dinner, fee, flights, homeShop], calendar: calendar).map(\.id), ["d"])
    }

    func testExcludedPaymentLeavesTheTrip() {
        var trip = Trip(name: "Rome", start: day(10), end: day(12), currency: "EUR")
        var gelato = BankTransaction(date: day(11), merchant: "Gelato", amount: -money("4.00"), fingerprint: "a")
        gelato.foreign = ForeignAmount(amount: money("4.60"), currency: "EUR")
        trip.excluded = ["a"]
        XCTAssertTrue(TripLedger.payments(for: trip, in: [gelato], calendar: calendar).isEmpty)
    }

    func testTripFlipsOwnerForThePartner() throws {
        let trip = Trip(name: "Rome", start: day(10), end: day(12), owner: .mine)
        let record = SyncRecord.records([trip], collection: "trips", id: \.id.uuidString)[0]
        let flipped = try SyncRecord.decoder().decode(Trip.self, from: HouseholdPerspective.flipped(record).payload)
        XCTAssertEqual(flipped.owner, .partner)
    }
}

final class SavingsGoalTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }

    func testProgressAndMonthlyNeeded() {
        let goal = SavingsGoal(name: "Japan", target: money("3000.00"), deadline: date(2027, 5, 31),
                               contributions: [.init(date: date(2026, 10, 1), amount: money("500.00")),
                                               .init(date: date(2026, 11, 1), amount: money("250.00"), by: .partner)])
        XCTAssertEqual(goal.saved, money("750.00"))
        XCTAssertEqual(goal.remaining, money("2250.00"))
        XCTAssertEqual(goal.progress, 0.25, accuracy: 0.0001)
        XCTAssertEqual(goal.saved(by: .partner), money("250.00"))
        // November to May is seven months, the deadline's own month included.
        XCTAssertEqual(goal.monthlyNeeded(today: date(2026, 11, 8), calendar: calendar), money("321.43"))
        XCTAssertNotNil(goal.projectedDate(today: date(2026, 11, 8), calendar: calendar))
    }

    func testReachedGoalNeedsNothing() {
        let goal = SavingsGoal(name: "Sofa", target: money("800.00"), deadline: date(2026, 12, 1), contributions: [.init(amount: money("800.00"))])
        XCTAssertTrue(goal.isReached)
        XCTAssertNil(goal.monthlyNeeded())
        XCTAssertFalse(goal.isBehind())
    }

    func testSharedGoalContributionsFlipForThePartner() throws {
        let goal = SavingsGoal(name: "Deposit", target: money("20000"), owner: .shared, contributions: [.init(amount: money("100"), by: .me)])
        let record = SyncRecord.records([goal], collection: "goals", id: \.id.uuidString)[0]
        let flipped = try SyncRecord.decoder().decode(SavingsGoal.self, from: HouseholdPerspective.flipped(record).payload)
        XCTAssertEqual(flipped.contributions.first?.by, .partner)
        XCTAssertEqual(flipped.owner, .shared)
        let back = try SyncRecord.decoder().decode(SavingsGoal.self, from: HouseholdPerspective.flipped(HouseholdPerspective.flipped(record)).payload)
        XCTAssertEqual(back.contributions.first?.by, .me)
    }
}
