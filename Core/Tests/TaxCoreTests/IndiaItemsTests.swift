import BudgetCore
import XCTest
@testable import TaxCore

final class IndiaItemsTests: XCTestCase {
    private func items(_ book: IndiaBook) -> IndiaItems {
        var items = IndiaItems()
        items.update(from: IndiaBook(), to: book)
        return items
    }

    private func privateAccount(_ id: String, in book: IndiaBook, _ isPrivate: Bool = true) -> IndiaBook {
        var book = book
        var account = book.account(id)!
        account.isPrivate = isPrivate
        book.save(account)
        return book
    }

    private func lines(_ items: IndiaItems, of account: String) -> [SyncRecord] {
        items.syncRecords().filter { $0.collection == "indiaEntries" && $0.id.hasPrefix(account) }
    }

    func testTheBookSurvivesItsSavedItems() {
        let book = IndiaSample.make()
        let saved = items(book)
        let read = IndiaItems(saved.records).book
        XCTAssertEqual(Set(read.accounts), Set(book.accounts))
        XCTAssertEqual(Set(read.entries), Set(book.entries))
        XCTAssertEqual(Set(read.rates), Set(book.rates))
        XCTAssertEqual(saved.unreadableCount, 0)
        XCTAssertTrue(Set(saved.records.map(\.collection)).isSubset(of: IndiaItems.collections))
        XCTAssertTrue(saved.records.allSatisfy { !$0.isPrivate })
    }

    func testLinesFollowTheirAccountsPrivacyBothWays() {
        let shared = IndiaSample.make()
        var saved = items(shared)
        let hidden = privateAccount("india-sample-sbi", in: shared)
        saved.update(from: shared, to: hidden)
        XCTAssertEqual(lines(saved, of: "india-sample-sbi").map(\.isPrivate), [true, true, true, true])
        XCTAssertEqual(lines(saved, of: "india-sample-icici").map(\.isPrivate), [false, false, false])
        saved.update(from: hidden, to: shared)
        XCTAssertEqual(lines(saved, of: "india-sample-sbi").map(\.isPrivate), [false, false, false, false])
    }

    func testALineWithoutItsAccountIsPrivate() {
        var book = IndiaSample.make()
        book.accounts.removeAll { $0.id == "india-sample-sbi" }
        XCTAssertTrue(lines(items(book), of: "india-sample-sbi").allSatisfy(\.isPrivate))
    }

    func testEditingNeverSharesAPrivateLineByGuessing() {
        let shared = IndiaSample.make()
        let hidden = privateAccount("india-sample-sbi", in: shared)
        var saved = items(hidden)
        // The account arrives shared again from another device; the lines haven't caught up.
        let account = items(shared).records.first { $0.key == "indiaAccounts|india-sample-sbi" }!
        XCTAssertTrue(saved.apply(saves: [account], deletes: []))
        XCTAssertTrue(lines(saved, of: "india-sample-sbi").allSatisfy(\.isPrivate))
        let old = saved.book
        var new = old
        var line = new.entries(of: "india-sample-sbi")[0]
        line.chosenKind = .interest
        new.save(line)
        saved.update(from: old, to: new)
        XCTAssertTrue(lines(saved, of: "india-sample-sbi").allSatisfy(\.isPrivate))
    }

    func testAnArrivingPrivateAccountTakesItsLinesWithItWhenSent() {
        let shared = IndiaSample.make()
        var saved = items(shared)
        let account = items(privateAccount("india-sample-sbi", in: shared)).records.first { $0.key == "indiaAccounts|india-sample-sbi" }!
        _ = saved.apply(saves: [account], deletes: [])
        XCTAssertTrue(lines(saved, of: "india-sample-sbi").allSatisfy(\.isPrivate))
    }

    func testDeletingAnAccountRemovesItsLines() {
        let book = IndiaSample.make()
        var saved = items(book)
        var new = book
        new.deleteAccount("india-sample-sbi")
        saved.update(from: book, to: new)
        XCTAssertTrue(lines(saved, of: "india-sample-sbi").isEmpty)
        XCTAssertEqual(saved.book.accounts.count, 2)
    }

    func testItemsFromANewerVersionAreKeptAsTheyAre() {
        let newer = SyncRecord(collection: "indiaEntries", id: "new", payload: Data(#"{"shape":"new"}"#.utf8), isPrivate: true)
        var saved = items(IndiaSample.make())
        _ = saved.apply(saves: [newer], deletes: [])
        XCTAssertEqual(saved.unreadableCount, 1)
        let old = saved.book
        var new = old
        new.setRate("2025-26", rupeesPerPound: 110)
        saved.update(from: old, to: new)
        XCTAssertTrue(saved.records.contains(newer))
    }

    func testRestoreTakesThePrivacyItsContentsCallFor() {
        let hidden = privateAccount("india-sample-sbi", in: IndiaSample.make())
        var saved = items(hidden)
        let line = lines(saved, of: "india-sample-sbi")[0]
        _ = saved.apply(saves: [], deletes: [line.key])
        saved.restore(SyncRecord(collection: line.collection, id: line.id, payload: line.payload))
        XCTAssertTrue(saved.holdsPrivately(line.key))
    }

    func testTheOtherPersonsSideSwapsWhoseAccountItIs() {
        let records = items(IndiaSample.make()).records
        let turned = IndiaItems(records.map(IndiaItems.flipped)).book
        XCTAssertEqual(turned.account("india-sample-icici")?.owner, .partner)
        XCTAssertEqual(turned.account("india-sample-sbi")?.owner, .shared)
        XCTAssertEqual(turned.account("india-sample-deposit")?.owner, .mine)
        XCTAssertEqual(records.map { IndiaItems.flipped(IndiaItems.flipped($0)) }, records)
    }
}
