import BudgetCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class Phase3StoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let csv = "Date,Description,Amount\r\n01/10/2026,TESCO STORES 3297,-12.40\r\n02/10/2026,JOE BLOGGS LTD,-5.00\r\n03/10/2026,NETFLIX.COM,-10.99\r\n"

    func testImportFillsInCategories() throws {
        let store = BudgetStore(folder: folder)
        let result = try store.previewImport(text: csv, fileName: "october.csv", mapping: nil)
        XCTAssertEqual(result.newTransactions.map(\.category), ["Groceries", "Uncategorised", "Subscriptions"])
    }

    func testImportUsesWhatYouChoseBefore() throws {
        let store = BudgetStore(folder: folder)
        store.transactions = [BankTransaction(date: Date(), merchant: "TESCO STORES 1111", amount: -3, category: "Family", fingerprint: "old")]
        let result = try store.previewImport(text: csv, fileName: "october.csv", mapping: nil)
        XCTAssertEqual(result.newTransactions.first?.category, "Family")
    }
}

@MainActor
final class SmartReceiptSettingTests: XCTestCase {
    func testSmartReadingIsOnByDefaultAndCanBeTurnedOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        XCTAssertTrue(AppSettings(defaults: defaults).smartReceiptsEnabled)
        AppSettings(defaults: defaults).smartReceiptsEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults).smartReceiptsEnabled)
    }

    func testAGoodReceiptNeverReachesTheModel() async {
        let parsed = ReceiptParser.parse(["CAFE", "Latte 3.20", "TOTAL 3.20"])
        XCTAssertFalse(ReceiptAIMerge.needsHelp(parsed))
        let improved = await ReceiptAIService.improve(parsed)
        XCTAssertEqual(improved.items, parsed.items, "Whatever the device supports, a balanced reading comes back unchanged")
    }
}

@MainActor
final class MerchantLookupStoreTests: XCTestCase {
    func testUnknownMerchantsGetLookedUpOnceAndFilledIn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BudgetStore(folder: folder)
        store.transactions = [
            BankTransaction(date: Date(), merchant: "))) BIKANERVALA HOUNSLOW", amount: -16.47, fingerprint: "a"),
            BankTransaction(date: Date(), merchant: "))) BIKANERVALA HOUNSLOW", amount: -17.98, fingerprint: "b"),
            BankTransaction(date: Date(), merchant: "MYSTERY LTD", amount: -5, fingerprint: "c"),
        ]
        var asked: [String] = []
        let filled = await store.categoriseUnknownMerchants(useAI: true, useMaps: false) { merchant in
            asked.append(merchant)
            return merchant.contains("BIKANERVALA") ? MerchantCategory(category: "Eating out", source: .maps) : nil
        }
        XCTAssertEqual(asked.count, 2, "Each merchant once")
        XCTAssertEqual(filled, 2)
        XCTAssertEqual(store.transactions.filter { $0.category == "Eating out" }.count, 2)
        XCTAssertEqual(BudgetStore(folder: folder).merchantCategories.count, 1, "Remembered")
    }

    func testNothingIsLookedUpWhenBothSwitchesAreOff() async {
        let store = BudgetStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.transactions = [BankTransaction(date: Date(), merchant: "MYSTERY LTD", amount: -5, fingerprint: "c")]
        let filled = await store.categoriseUnknownMerchants(useAI: false, useMaps: false) { _ in XCTFail("No lookup"); return nil }
        XCTAssertEqual(filled, 0)
    }
}
