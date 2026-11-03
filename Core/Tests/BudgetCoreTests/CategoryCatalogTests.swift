import XCTest
@testable import BudgetCore

final class CategoryCatalogTests: XCTestCase {
    private func payment(_ category: String, _ subcategory: String? = nil, amount: Decimal = Decimal(string: "-12.50")!) -> BankTransaction {
        var transaction = BankTransaction(date: Date(), merchant: "SHOP", amount: amount, category: category, fingerprint: UUID().uuidString)
        transaction.subcategory = subcategory
        return transaction
    }

    func testDefaultCatalogMatchesTheBuiltInList() {
        let catalog = CategoryCatalog.default
        XCTAssertEqual(catalog.all, FinanceCategories.builtInNames)
        XCTAssertFalse(catalog.budgetable.contains("Income"))
        XCTAssertEqual(catalog.subcategories(of: "Groceries"), FinanceCategories.defaultSubcategories["Groceries"])
        XCTAssertTrue(catalog.changed.isEmpty)
        XCTAssertTrue(CategoryNormaliser(catalog: catalog).isIdentity)
    }

    func testRenameMovesPaymentsRulesAndLookUps() throws {
        var catalog = CategoryCatalog.default
        try catalog.rename("Groceries", to: "Food shopping")
        XCTAssertTrue(catalog.all.contains("Food shopping"))
        XCTAssertFalse(catalog.all.contains("Groceries"))
        XCTAssertEqual(catalog.resolve("Groceries"), "Food shopping", "Starter rules and look-ups still say Groceries")
        XCTAssertEqual(catalog.subcategories(of: "Food shopping"), FinanceCategories.defaultSubcategories["Groceries"])

        var normaliser = CategoryNormaliser(catalog: catalog)
        var transactions = [payment("Groceries", "Supermarket"), payment("Transport")]
        XCTAssertTrue(normaliser.normalise(&transactions))
        XCTAssertEqual(transactions[0].category, "Food shopping")
        XCTAssertEqual(transactions[0].subcategory, "Supermarket")
        XCTAssertEqual(transactions[1].category, "Transport")

        var rules = [CategoryRule(name: "Tesco", conditions: [.init(.description, .contains, "TESCO")], category: "Groceries", subcategory: "Supermarket")]
        XCTAssertTrue(normaliser.normalise(&rules))
        XCTAssertEqual(rules[0].category, "Food shopping")
        XCTAssertEqual(rules[0].subcategory, "Supermarket")

        var lookedUp = ["ACME": MerchantCategory(category: "Groceries", source: .maps)]
        XCTAssertTrue(normaliser.normalise(&lookedUp))
        XCTAssertEqual(lookedUp["ACME"]?.category, "Food shopping")

        // Renaming again still finds payments that use the first name.
        try catalog.rename("Groceries", to: "Food")
        XCTAssertEqual(catalog.resolve("Food shopping"), "Food")
        XCTAssertEqual(catalog.resolve("Groceries"), "Food")
    }

    func testNamesMustBeUniqueAndLockedCategoriesKeepTheirNames() {
        var catalog = CategoryCatalog.default
        XCTAssertThrowsError(try catalog.rename("Groceries", to: "transport")) { XCTAssertEqual($0 as? CategoryEditError, .nameTaken) }
        XCTAssertThrowsError(try catalog.rename("Groceries", to: "  ")) { XCTAssertEqual($0 as? CategoryEditError, .emptyName) }
        XCTAssertThrowsError(try catalog.rename("Income", to: "Money in")) { XCTAssertEqual($0 as? CategoryEditError, .builtInLocked) }
        XCTAssertThrowsError(try catalog.delete("Uncategorised", movingTo: "Groceries")) { XCTAssertEqual($0 as? CategoryEditError, .builtInLocked) }
        XCTAssertThrowsError(try catalog.add(name: "Uncategorised", symbol: "star", color: .violet)) { XCTAssertEqual($0 as? CategoryEditError, .nameTaken) }
        XCTAssertThrowsError(try catalog.deleteSubcategory("Refund", in: "Income")) { XCTAssertEqual($0 as? CategoryEditError, .builtInLocked) }
        // Icons and colours of locked categories can still change.
        XCTAssertNoThrow(try catalog.setLook("Income", symbol: "sterlingsign.circle", color: .teal))
        XCTAssertEqual(catalog.definition(id: "Income")?.color, .teal)
    }

    func testOwnCategoriesAreSpendingAndSitBeforeIncome() throws {
        var catalog = CategoryCatalog.default
        let pets = try catalog.add(name: "Pets", symbol: "pawprint", color: .amber)
        try catalog.addSubcategory("Vet", to: pets.id)
        XCTAssertTrue(catalog.budgetable.contains("Pets"))
        XCTAssertEqual(catalog.all.firstIndex(of: "Pets").map { $0 + 1 }, catalog.all.firstIndex(of: "Savings & investments"))
        XCTAssertEqual(catalog.subcategories(of: "Pets"), ["Vet"])

        // Saved and loaded on another device, it comes back the same.
        let reloaded = CategoryCatalog(saved: catalog.changed)
        XCTAssertEqual(reloaded.all, catalog.all)
        XCTAssertEqual(reloaded.definition(id: pets.id)?.symbol, "pawprint")
    }

    func testDeleteMovesPaymentsAndBudgetsToTheChosenCategory() throws {
        var catalog = CategoryCatalog.default
        try catalog.delete("Education", movingTo: "Family")
        XCTAssertFalse(catalog.all.contains("Education"))
        XCTAssertEqual(catalog.resolve("Education"), "Family")

        var normaliser = CategoryNormaliser(catalog: catalog)
        var transactions = [payment("Education", "Courses"), payment("Education")]
        normaliser.normalise(&transactions)
        XCTAssertEqual(transactions.map(\.category), ["Family", "Family"])
        XCTAssertNil(transactions[0].subcategory, "Courses isn't a Family sub-category")

        let month = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 1).date!
        var budgets = [
            MonthlyBudget(category: "Family", limit: Decimal(string: "200.10")!, month: month),
            MonthlyBudget(category: "Education", limit: Decimal(string: "50.25")!, month: month),
        ]
        XCTAssertTrue(normaliser.normalise(&budgets))
        XCTAssertEqual(budgets.count, 1)
        XCTAssertEqual(budgets[0].limit, Decimal(string: "250.35")!)

        // Deleting the category it went to sends both on to the next one.
        try catalog.delete("Family", movingTo: "Housing")
        XCTAssertEqual(catalog.resolve("Education"), "Housing")
    }

    func testDeletedCustomCategoryStillCatchesLatePayments() throws {
        var catalog = CategoryCatalog.default
        let pets = try catalog.add(name: "Pets", symbol: "pawprint", color: .amber)
        try catalog.delete(pets.id, movingTo: "Family")
        let reloaded = CategoryCatalog(saved: catalog.changed)
        XCTAssertEqual(reloaded.resolve("Pets"), "Family", "A payment from a device that hadn't heard yet")
        // The name is free again.
        var again = reloaded
        XCTAssertNoThrow(try again.add(name: "Pets", symbol: "pawprint", color: .amber))
        XCTAssertEqual(again.resolve("Pets"), "Pets", "A category using the name now wins")
    }

    func testSubcategoryRenameAndDelete() throws {
        var catalog = CategoryCatalog.default
        try catalog.renameSubcategory("Coffee", to: "Coffee shops", in: "Eating out")
        try catalog.deleteSubcategory("Fast food", in: "Eating out", movingTo: "Takeaway")
        try catalog.deleteSubcategory("Pub and bar", in: "Eating out")
        XCTAssertFalse(catalog.subcategories(of: "Eating out").contains("Coffee"))
        XCTAssertTrue(catalog.subcategories(of: "Eating out").contains("Coffee shops"))

        XCTAssertEqual(catalog.resolve(category: "Eating out", subcategory: "Coffee").subcategory, "Coffee shops")
        XCTAssertEqual(catalog.resolve(category: "Eating out", subcategory: "Fast food").subcategory, "Takeaway")
        XCTAssertNil(catalog.resolve(category: "Eating out", subcategory: "Pub and bar").subcategory)

        try catalog.renameSubcategory("Coffee shops", to: "Cafés", in: "Eating out")
        XCTAssertEqual(catalog.resolve(category: "Eating out", subcategory: "Coffee").subcategory, "Cafés")

        // A rename of the category keeps sub-category moves working.
        try catalog.rename("Eating out", to: "Dining")
        XCTAssertEqual(catalog.resolve(category: "Eating out", subcategory: "Coffee").category, "Dining")
        XCTAssertEqual(catalog.resolve(category: "Eating out", subcategory: "Coffee").subcategory, "Cafés")
    }

    func testRestoreBuiltInBringsNamesBackAndKeepsOwnCategories() throws {
        var catalog = CategoryCatalog.default
        try catalog.rename("Groceries", to: "Food")
        try catalog.renameSubcategory("Supermarket", to: "Big shop", in: "Groceries")
        try catalog.setLook("Groceries", symbol: "basket", color: .violet)
        try catalog.delete("Education", movingTo: "Family")
        let pets = try catalog.add(name: "Pets", symbol: "pawprint", color: .amber)

        catalog.restoreBuiltIn()
        XCTAssertTrue(catalog.all.contains("Groceries"))
        XCTAssertTrue(catalog.all.contains("Education"))
        XCTAssertTrue(catalog.all.contains("Pets"))
        XCTAssertEqual(catalog.definition(id: "Groceries")?.symbol, "cart")
        XCTAssertEqual(catalog.resolve("Food"), "Groceries", "Payments come back from the renamed name")
        XCTAssertEqual(catalog.resolve(category: "Food", subcategory: "Big shop").subcategory, "Supermarket")
        XCTAssertNotNil(catalog.definition(id: pets.id))
    }

    func testLockedCategoryCannotBeRenamedByArrivingData() {
        var income = CategoryCatalog.builtIn.first { $0.id == "Income" }!
        income.name = "Money"
        income.isDeleted = true
        let catalog = CategoryCatalog(saved: [income])
        XCTAssertTrue(catalog.all.contains("Income"))
    }

    func testReceiptItemsSplitsAndCoupleRulesFollow() throws {
        var catalog = CategoryCatalog.default
        try catalog.rename("Health", to: "Wellbeing")
        var normaliser = CategoryNormaliser(catalog: catalog)

        var transaction = payment("Groceries")
        transaction.splits = [TransactionSplit(label: "Paracetamol", category: "Health", amount: Decimal(string: "-1.99")!)]
        XCTAssertTrue(normaliser.normalise(&transaction))
        XCTAssertEqual(transaction.splits[0].category, "Wellbeing")

        var editor = ReceiptDraftEditor(items: [ReceiptLineItem(description: "Plasters", total: Decimal(string: "2.49")!, category: "Health", confidence: 0.9)])
        XCTAssertTrue(normaliser.normalise(&editor))
        XCTAssertEqual(editor.items[0].category, "Wellbeing")

        var couple = CoupleSettings(rules: [OwnerRule(match: .category("Health"), owner: .shared)])
        XCTAssertTrue(normaliser.normalise(&couple))
        XCTAssertEqual(couple.rules[0].match, .category("Wellbeing"))
    }

    func testUnknownCategoryNamesAreLeftAlone() {
        var normaliser = CategoryNormaliser(catalog: .default)
        var transaction = payment("Something from another device")
        XCTAssertFalse(normaliser.normalise(&transaction))
        XCTAssertEqual(transaction.category, "Something from another device")
    }
}
