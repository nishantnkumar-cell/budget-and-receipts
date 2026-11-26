import BudgetCore
import TaxCore
import XCTest
@testable import BudgetReceipts

@MainActor
final class IndiaStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let account = IndiaAccount(id: "a", bank: .icici, kind: .nro, lastFour: "1111")

    private func store(_ name: String = "") -> IndiaStore {
        IndiaStore(folder: name.isEmpty ? folder : folder.appendingPathComponent(name))
    }

    /// An account with one line of interest.
    private func filled(_ store: IndiaStore, _ account: IndiaAccount) {
        store.change { book in
            book.save(account)
            book.save(IndiaEntry(id: "line", accountID: account.id, date: TaxYear.day(2026, 6, 30), narration: "CREDIT INTEREST", amount: 100))
        }
    }

    func testChangesAreSavedAndSent() {
        let india = store()
        var sends = 0
        india.didPersist = { sends += 1 }
        filled(india, account)
        india.change { _ in }
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(store().book, india.book)
        XCTAssertEqual(india.syncRecords().map(\.key), ["indiaAccounts|a", "indiaEntries|line"])
    }

    func testNothingIsWrittenUntilSomethingIsEntered() {
        XCTAssertTrue(store().applySync(saves: [], deletes: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("india-items.json").path))
    }

    func testImportedLinesSurviveALaunchAndAreNotAddedTwice() throws {
        let india = store()
        india.change { $0.save(account) }
        let statement = try IndiaStatement.read(text: IndiaSample.iciciStatement)
        for _ in 0..<2 {
            india.change { book in book.entries += statement.entries(for: "a", existing: book.entries).new }
        }
        XCTAssertEqual(store().book.entries.count, 3)
        XCTAssertEqual(store().book.balance(of: "a")?.rupees, 493_650)
    }

    func testAPartnerSeesAccountsFromTheirOwnSideAndSendsThemBackUnchanged() {
        let owner = store("owner")
        owner.setHouseholdRole(.owner)
        filled(owner, account)
        let sent = owner.syncRecords()
        let member = store("member")
        member.setHouseholdRole(.member)
        XCTAssertTrue(member.applySync(saves: sent, deletes: []))
        XCTAssertEqual(member.book.accounts.first?.owner, .partner)
        XCTAssertEqual(member.syncRecords(), sent)
    }

    func testAPrivateAccountIsNeverTurnedRoundOrShared() {
        let member = store()
        member.setHouseholdRole(.member)
        var hidden = account
        hidden.isPrivate = true
        filled(member, hidden)
        let sent = member.syncRecords()
        XCTAssertTrue(sent.allSatisfy(\.isPrivate))
        XCTAssertEqual(IndiaItems(sent).book.accounts.first?.owner, .mine)
    }

    func testAPartnerCantChangeWhatIsPrivateHere() throws {
        let india = store()
        india.setHouseholdRole(.owner)
        var hidden = account
        hidden.isPrivate = true
        filled(india, hidden)
        var theirs = india.syncRecords()[0]
        theirs.payload = try SyncRecord.encoder().encode(account)
        theirs.isPrivate = false
        theirs.byPartner = true
        XCTAssertTrue(india.applySync(saves: [theirs], deletes: []))
        XCTAssertEqual(india.rejectedKeys([theirs]), ["indiaAccounts|a"])
        XCTAssertEqual(india.book.accounts, [hidden])
    }

    func testAnotherDevicesDeletionCanBeRestoredAccountFirst() {
        let india = store()
        var changes: [RecentChange] = []
        india.didReceiveChanges = { changes += $0 }
        filled(india, account)
        XCTAssertTrue(india.applySync(saves: [], deletes: ["indiaAccounts|a", "indiaEntries|line"]))
        XCTAssertEqual(changes.count, 2)
        // Handed over lines first: they still come back shared, like their account.
        india.restore(changes.sorted { $0.collection > $1.collection })
        XCTAssertEqual(india.book.accounts, [account])
        XCTAssertEqual(india.book.entries.count, 1)
        XCTAssertTrue(india.syncRecords().allSatisfy { !$0.isPrivate })
    }

    func testAPartnerWhoStopsSharingCantHaveItPutBack() {
        for owner in [MoneyOwner.partner, .shared, .mine] {
            let india = store(owner.rawValue)
            india.setHouseholdRole(.owner)
            var changes: [RecentChange] = []
            india.didReceiveChanges = { changes += $0 }
            var theirs = account
            theirs.owner = owner
            filled(india, theirs)
            india.applySync(saves: [], deletes: ["indiaAccounts|a", "indiaEntries|line"])
            XCTAssertEqual(changes.count, owner == .mine ? 2 : 0, owner.rawValue)
        }
    }

    func testABackupWithoutIndiaAccountsLeavesThem() throws {
        let budget = BudgetStore(folder: folder)
        let backup = try EncryptedBackup.make(folder: folder, password: "long enough", device: "", appVersion: "")
        let india = store()
        filled(india, account)
        try budget.restore(EncryptedBackup.open(backup, password: "long enough"), subscriptions: SubscriptionStore(folder: folder),
                           tax: TaxStore(folder: folder), india: india, held: HeldItemsStore(folder: folder, known: []))
        XCTAssertEqual(store().book.accounts, [account])
    }

    func testABackupCarriesThem() throws {
        let budget = BudgetStore(folder: folder)
        let india = store()
        filled(india, account)
        let backup = try EncryptedBackup.make(folder: folder, password: "long enough", device: "", appVersion: "")
        india.resetAllData()
        try budget.restore(EncryptedBackup.open(backup, password: "long enough"), subscriptions: SubscriptionStore(folder: folder),
                           tax: TaxStore(folder: folder), india: india, held: HeldItemsStore(folder: folder, known: india.collections))
        XCTAssertEqual(india.book.accounts, [account])
        XCTAssertEqual(india.book.entries.count, 1)
    }

    func testItemsHeldBeforeThisVersionAreTakenOver() {
        let sender = store("sender")
        filled(sender, account)
        let held = HeldItemsStore(folder: folder, known: [])
        held.applySync(saves: sender.syncRecords(), deletes: [])
        let india = store("receiver")
        held.release(to: [india, held])
        XCTAssertEqual(india.book, sender.book)
        XCTAssertTrue(held.syncRecords().isEmpty)
    }
}
