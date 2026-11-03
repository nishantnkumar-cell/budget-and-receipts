import BudgetCore
import SwiftUI
import XCTest
@testable import BudgetReceipts

@MainActor
final class ReportsStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func payment(_ merchant: String, _ amount: String, owner: MoneyOwner?, account: UUID? = nil) -> BankTransaction {
        var transaction = BankTransaction(date: Date(), merchant: merchant, amount: Decimal(string: amount)!, category: "Groceries", fingerprint: UUID().uuidString, owner: owner)
        transaction.accountID = account
        return transaction
    }

    func testReportsFollowTheHouseholdSwitchAndAccountFilter() {
        let store = BudgetStore(folder: folder)
        store.updateCouple(CoupleSettings(partnerName: "Priya"))
        let joint = store.addAccount(name: "Joint")
        store.transactions = [payment("TESCO", "-100.00", owner: .shared, account: joint.id), payment("WAITROSE", "-30.00", owner: .partner)]
        XCTAssertEqual(store.cashFlow(months: 3).totalSpending, 130)
        store.householdView = .me
        XCTAssertEqual(store.cashFlow(months: 3).totalSpending, 50, "My half of the shared shop, none of Priya's")
        XCTAssertEqual(store.topShops(months: 3).map(\.name), ["Tesco"])
        store.householdView = .together
        store.accountFilter = joint.id
        XCTAssertEqual(store.categoryTrends(months: 3).categories.first?.category.total, 100)
    }

    func testReportPDFHasContent() {
        let store = BudgetStore(folder: folder)
        store.transactions = [payment("TESCO", "-100.00", owner: nil)]
        let pdf = ReportPDF.render(title: "Cash flow", CashFlowSection(report: store.cashFlow(months: 3), printing: true).environmentObject(store))
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(pdf.count, 2_000)
    }
}
