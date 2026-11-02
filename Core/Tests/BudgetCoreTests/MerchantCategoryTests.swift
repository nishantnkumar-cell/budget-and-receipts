import XCTest
@testable import BudgetCore

final class MerchantCategoryTests: XCTestCase {
    private func tx(_ merchant: String, _ amount: String = "-10.00", category: String = "Uncategorised") -> BankTransaction {
        BankTransaction(date: Date(), merchant: merchant, amount: money(amount), category: category, fingerprint: UUID().uuidString)
    }

    func testLookedUpCategoryIsUsedAfterYourChoicesAndTheBuiltInList() {
        let found = ["BIKANERVALA HOUNSLOW": MerchantCategory(category: "Eating out", source: .maps)]
        XCTAssertEqual(Categoriser(lookedUp: found).suggest(for: tx("))) BIKANERVALA HOUNSLOW"))?.category, "Eating out")
        XCTAssertEqual(Categoriser(lookedUp: found).suggest(for: tx("BIKANERVALA HOUNSLOW"))?.source, .lookedUp)
        let mine = Categoriser(history: [tx("BIKANERVALA HOUNSLOW", category: "Family")], lookedUp: found)
        XCTAssertEqual(mine.suggest(for: tx("BIKANERVALA HOUNSLOW"))?.category, "Family", "Your own choice wins")
        let tesco = ["TESCO STORES": MerchantCategory(category: "Shopping", source: .ai)]
        XCTAssertEqual(Categoriser(lookedUp: tesco).suggest(for: tx("TESCO STORES 1234"))?.category, "Groceries", "The built-in list wins")
    }

    func testOnlyRealCategoriesAreAccepted() {
        XCTAssertEqual(MerchantCategories.validated(" eating out "), "Eating out")
        XCTAssertNil(MerchantCategories.validated("Uncategorised"))
        XCTAssertNil(MerchantCategories.validated("Coffee"))
        XCTAssertNil(MerchantCategories.validated("Internal transfer"))
        XCTAssertNil(MerchantCategories.validated(nil))
    }

    func testSearchTextDropsCardWording() {
        XCTAssertEqual(MerchantCategories.searchText("CARD PAYMENT TO SADDA SUPERSTORE LTD HOUNSLOW 1234"), "SADDA SUPERSTORE LTD HOUNSLOW")
        XCTAssertEqual(MerchantCategories.searchText("))) Franco Manca Kingston London"), "FRANCO MANCA KINGSTON LONDON")
    }

    func testUnknownMerchantsAreListedOnce() {
        let transactions = [tx("BIKANERVALA HOUNSLOW"), tx("BIKANERVALA HOUNSLOW 2"), tx("TESCO STORES"), tx("ACME", "100.00"), tx("ODD PLACE", category: "Family")]
        XCTAssertEqual(MerchantCategories.unknownMerchants(transactions, known: [:], categoriser: Categoriser()), ["BIKANERVALA HOUNSLOW"])
        XCTAssertTrue(MerchantCategories.unknownMerchants(transactions, known: ["BIKANERVALA HOUNSLOW": .init(category: "Eating out", source: .ai)], categoriser: Categoriser()).isEmpty)
    }

    func testMapsKindsMapToCategories() {
        XCTAssertEqual(MerchantCategories.mapsCategories["MKPOICategoryRestaurant"], "Eating out")
        XCTAssertEqual(MerchantCategories.mapsCategories["MKPOICategoryFoodMarket"], "Groceries")
        XCTAssertTrue(MerchantCategories.mapsCategories.values.allSatisfy { FinanceCategories.all.contains($0) })
    }
}
