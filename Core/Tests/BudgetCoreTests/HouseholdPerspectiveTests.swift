import XCTest
@testable import BudgetCore

final class HouseholdPerspectiveTests: XCTestCase {
    private func record<T: Encodable>(_ value: T, _ collection: String) -> SyncRecord {
        SyncRecord.records([value], collection: collection, id: { _ in "x" })[0]
    }

    private func decode<T: Decodable>(_ record: SyncRecord, as type: T.Type) -> T {
        try! SyncRecord.decoder().decode(T.self, from: record.payload)
    }

    func testMineAndPartnerSwapForTheOtherPerson() {
        var transaction = BankTransaction(date: Date(timeIntervalSince1970: 0), merchant: "Tesco", amount: -10, fingerprint: "a", splits: [
            TransactionSplit(label: "Shampoo", category: "Health", amount: 4, owner: .partner),
            TransactionSplit(label: "Food", category: "Groceries", amount: 6, owner: .shared),
        ], owner: .mine, paidBy: .partner)
        transaction.isPrivate = nil
        let flipped = decode(HouseholdPerspective.flipped(record(transaction, "transactions")), as: BankTransaction.self)
        XCTAssertEqual(flipped.owner, .partner)
        XCTAssertEqual(flipped.paidBy, .me)
        XCTAssertEqual(flipped.splits.map(\.owner), [.mine, .shared])
    }

    func testTurningTwiceGivesTheOriginal() {
        let couple = CoupleSettings(partnerName: "Shweta", myShare: Decimal(string: "0.6")!, rules: [OwnerRule(match: .merchant("Netflix"), owner: .mine)], defaultOwner: .shared)
        var withOwner = couple
        withOwner.ownerName = "Nishant"
        let once = HouseholdPerspective.flipped(record(withOwner, "couple"))
        let seen = decode(once, as: CoupleSettings.self)
        XCTAssertEqual(seen.partnerName, "Nishant")
        XCTAssertEqual(seen.ownerName, "Shweta")
        XCTAssertEqual(seen.myShare, Decimal(string: "0.4"))
        XCTAssertEqual(seen.rules.first?.owner, .partner)
        XCTAssertEqual(decode(HouseholdPerspective.flipped(once), as: CoupleSettings.self), withOwner)
    }

    func testWhoPaidWhomSwaps() {
        let settlement = Settlement(date: Date(timeIntervalSince1970: 0), from: .partner, amount: 25)
        XCTAssertEqual(decode(HouseholdPerspective.flipped(record(settlement, "settlements")), as: Settlement.self).from, .me)
    }

    func testOtherCollectionsAreUntouched() {
        let budget = MonthlyBudget(category: "Groceries", limit: 200, month: Date(timeIntervalSince1970: 0))
        let original = record(budget, "budgets")
        XCTAssertEqual(HouseholdPerspective.flipped(original).payload, original.payload)
    }
}
