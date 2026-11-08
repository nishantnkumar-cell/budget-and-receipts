import BudgetCore
import XCTest
@testable import BudgetReceipts

/// Savings goals, reimbursements and trips: saved, synced, edited and deleted.
@MainActor
final class GoalsTripsStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testGoalSurvivesRelaunchAndCanBeDeleted() {
        let store = BudgetStore(folder: folder)
        var goal = SavingsGoal(name: "Japan", target: Decimal(string: "3000")!)
        store.saveGoal(goal)
        store.addContribution(.init(amount: Decimal(string: "250.50")!), to: goal)
        goal = BudgetStore(folder: folder).goals[0]
        XCTAssertEqual(goal.saved, Decimal(string: "250.50")!)
        goal.contributions = []
        store.saveGoal(goal)
        XCTAssertEqual(BudgetStore(folder: folder).goals.first?.saved, 0)
        store.deleteGoal(goal)
        XCTAssertTrue(BudgetStore(folder: folder).goals.isEmpty)
    }

    func testPrivateGoalSyncsPrivately() {
        let store = BudgetStore(folder: folder)
        store.saveGoal(SavingsGoal(name: "Surprise", target: 500, isPrivate: true))
        store.saveTrip(Trip(name: "Rome", start: Date(), end: Date()))
        let records = store.syncRecords()
        XCTAssertEqual(records.first { $0.collection == "goals" }?.isPrivate, true)
        XCTAssertEqual(records.first { $0.collection == "trips" }?.isPrivate, false)
        let other = BudgetStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        other.applySync(saves: records.filter { $0.collection == "goals" || $0.collection == "trips" }, deletes: [])
        XCTAssertEqual(other.goals.first?.name, "Surprise")
        XCTAssertEqual(other.trips.first?.name, "Rome")
    }

    func testRepaymentLinkFollowsEditsAndDeletes() {
        let store = BudgetStore(folder: folder)
        var lunch = BankTransaction(date: Date().addingTimeInterval(-86_400 * 10), merchant: "Client lunch", amount: -42, category: "Eating out", fingerprint: "pay")
        let back = BankTransaction(date: Date(), merchant: "ACME EXPENSES", amount: 42, category: "Income", fingerprint: "back")
        store.transactions = [back, lunch]
        lunch.reimbursement = Reimbursement(from: "Work", amount: 42)
        store.update(lunch)
        XCTAssertEqual(store.outstandingReimbursements.count, 1)
        store.markRepaid(lunch, by: back)
        XCTAssertEqual(store.transactions.first { $0.id == "back" }?.repays, "pay")
        XCTAssertTrue(store.outstandingReimbursements.isEmpty)
        XCTAssertEqual(store.calculator.income(store.transactions, month: Date()), 0)
        // Taking the mark off lets the credit count as income again.
        store.setReimbursement(nil, for: lunch)
        XCTAssertNil(store.transactions.first { $0.id == "back" }?.repays)
    }

    func testTripCollectsForeignPaymentsAndCanLoseOne() {
        let store = BudgetStore(folder: folder)
        let trip = Trip(name: "Lisbon", start: Date().addingTimeInterval(-86_400 * 3), end: Date(), currency: "EUR")
        store.saveTrip(trip)
        store.transactions = [
            BankTransaction(date: Date().addingTimeInterval(-86_400), merchant: "PASTEIS EUR 11.60", amount: -10, category: "Eating out", fingerprint: "a"),
            BankTransaction(date: Date().addingTimeInterval(-86_400), merchant: "NON-STERLING TRANSACTION FEE", amount: Decimal(string: "-0.28")!, category: "Fees & charges", fingerprint: "b"),
        ]
        UserDefaults.standard.removeObject(forKey: "readForeignAmounts")
        store.readForeignAmounts()
        XCTAssertEqual(store.summary(of: trip).total, Decimal(string: "10.28")!)
        XCTAssertEqual(store.summary(of: trip).averageRate, Decimal(string: "1.16")!)
        store.removeFromTrip(store.transactions[1], trip: trip)
        XCTAssertEqual(store.summary(of: trip).total, 10)
        store.deleteTrip(trip)
        XCTAssertTrue(BudgetStore(folder: folder).trips.isEmpty)
    }
}
