import BudgetCore
import XCTest
@testable import TaxCore

final class TaxItemsTests: XCTestCase {
    private func items(_ book: PropertyBook, private fingerprints: Set<String> = []) -> TaxItems {
        var items = TaxItems()
        items.update(from: PropertyBook(), to: book, isPrivatePayment: fingerprints.contains)
        return items
    }

    func testTheBookSurvivesItsSavedItems() {
        let book = TaxSample.make().book
        let saved = items(book)
        let read = TaxItems(saved.records).book
        XCTAssertEqual(read.properties, book.properties)
        XCTAssertEqual(read.rules, book.rules)
        XCTAssertEqual(Set(read.assignments), Set(book.assignments))
        XCTAssertEqual(read.statements.map(\.id).sorted(), book.statements.map(\.id).sorted())
        XCTAssertEqual(read.interest, book.interest)
        XCTAssertEqual(Set(read.pay), Set(book.pay))
        XCTAssertEqual(saved.unreadableCount, 0)
        XCTAssertTrue(Set(saved.records.map(\.collection)).isSubset(of: TaxItems.collections))
    }

    func testPayIsPrivateUnlessSharedAndItemsFollowTheirPayment() {
        var book = TaxSample.make().book
        book.rules[0].isPrivate = true
        let records = items(book, private: ["tax-sample-plumber", "tax-sample-rent-0"]).records
        func record(_ collection: String, _ id: String) -> SyncRecord? { records.first { $0.key == SyncRecord.key(collection, id) } }
        XCTAssertEqual(record("taxPay", "job-me")?.isPrivate, true)
        XCTAssertEqual(record("taxPay", "job-partner")?.isPrivate, false)
        XCTAssertEqual(record("taxPayments", "tax-sample-plumber")?.isPrivate, true)
        XCTAssertEqual(record("taxPayments", "tax-sample-kitchen")?.isPrivate, false)
        XCTAssertEqual(record("taxStatements", "statement-0")?.isPrivate, true)
        XCTAssertEqual(record("taxRules", "private|sample bank mortgage")?.isPrivate, true)
        XCTAssertEqual(record("taxProperties", "flat")?.isPrivate, false)
    }

    func testAnItemBecomesPrivateAtOnceButSharedOnlyWhenYouChangeThePayment() {
        var saved = items(TaxSample.make().book, private: ["tax-sample-plumber"])
        let key = "taxPayments|tax-sample-plumber"
        func sent(_ privacy: Bool?) -> Bool? { saved.syncRecords { _ in privacy }.first { $0.key == key }?.isPrivate }
        XCTAssertEqual(sent(false), true)
        XCTAssertEqual(sent(nil), true)
        saved.followPrivacy(of: ["tax-sample-plumber"]) { _ in false }
        XCTAssertEqual(sent(false), false)
        XCTAssertEqual(sent(true), true)
    }

    func testAnItemWhosePaymentIsntHereIsNeverSharedByGuessing() {
        let book = TaxSample.make().book
        var saved = TaxItems()
        saved.update(from: PropertyBook(), to: book, isPrivatePayment: { _ in nil })
        XCTAssertTrue(saved.records.filter { $0.collection == "taxPayments" || $0.collection == "taxStatements" }.allSatisfy(\.isPrivate))
        // An edit to a shared item keeps it shared.
        var shared = items(book)
        let old = shared.book
        var new = old
        new.statements[0].fees += 1
        shared.update(from: old, to: new, isPrivatePayment: { _ in nil })
        XCTAssertEqual(shared.records.first { $0.key == "taxStatements|\(new.statements[0].id)" }?.isPrivate, false)
    }

    func testEditingAPrivateItemNeverSharesIt() {
        // A device that hasn't heard the payment was made private edits the item.
        var saved = items(TaxSample.make().book, private: ["tax-sample-plumber"])
        let key = "taxPayments|tax-sample-plumber"
        XCTAssertTrue(saved.holdsPrivately(key))
        let old = saved.book
        var new = old
        let index = new.assignments.firstIndex { $0.fingerprint == "tax-sample-plumber" }!
        new.assignments[index].category = .capital
        saved.update(from: old, to: new, isPrivatePayment: { _ in false })
        XCTAssertEqual(saved.records.first { $0.key == key }?.isPrivate, true)
        XCTAssertFalse(saved.holdsPrivately("taxProperties|flat"))
    }

    func testLinkingAStatementToAnotherPaymentFollowsThatPayment() {
        var saved = items(TaxSample.make().book, private: ["tax-sample-rent-0"])
        let old = saved.book
        var new = old
        let index = new.statements.firstIndex { $0.id == "statement-0" }!
        new.statements[index].bankFingerprint = "another"
        saved.update(from: old, to: new, isPrivatePayment: { _ in false })
        XCTAssertEqual(saved.records.first { $0.key == "taxStatements|statement-0" }?.isPrivate, false)
    }

    func testOnlyMyOwnEntriesAreGuarded() {
        var book = TaxSample.make().book
        book.pay[0].enteredBy = .partner
        let saved = items(book)
        XCTAssertFalse(saved.isMyOwnEntry("taxPay|\(book.pay[0].id)"))
        XCTAssertTrue(saved.isMyOwnEntry("taxPay|\(book.pay[1].id)"))
        XCTAssertFalse(saved.isMyOwnEntry("taxProperties|flat"))
    }

    func testAnUntouchedItemKeepsWhatANewerVersionAdded() {
        let property = RentalProperty(id: "p", name: "Flat")
        var saved = items(PropertyBook(properties: [property]))
        var record = saved.records[0]
        record.payload = Data(#"{"form17":false,"id":"p","myShare":0.5,"name":"Flat","newField":1}"#.utf8)
        XCTAssertTrue(saved.apply(saves: [record], deletes: []))
        let old = saved.book
        var new = old
        new.interest.append(MortgageInterest(propertyID: "p", taxYear: "2025-26", interestAndFees: 5))
        saved.update(from: old, to: new, isPrivatePayment: { _ in false })
        XCTAssertEqual(saved.records.first { $0.collection == "taxProperties" }?.payload, record.payload)
    }

    func testAnItemThatCantBeReadIsKeptNotDeleted() {
        let strange = SyncRecord(collection: "taxPayments", id: "x", payload: Data(#"{"category":"somethingNew"}"#.utf8))
        var saved = TaxItems([strange])
        XCTAssertEqual(saved.unreadableCount, 1)
        XCTAssertTrue(saved.book.assignments.isEmpty)
        var next = saved.book
        next.properties.append(RentalProperty(id: "p", name: "Flat"))
        saved.update(from: saved.book, to: next, isPrivatePayment: { _ in false })
        XCTAssertTrue(saved.records.contains(strange))
        XCTAssertEqual(saved.syncRecords { _ in nil }.count, 2)
    }

    func testArrivalsAndDeletionsApplyOnlyToTaxItems() {
        var saved = items(TaxSample.make().book)
        let count = saved.records.count
        let other = SyncRecord(collection: "transactions", id: "t", payload: Data())
        XCTAssertFalse(saved.apply(saves: [other], deletes: []))
        XCTAssertTrue(saved.apply(saves: [], deletes: ["taxProperties|flat"]))
        XCTAssertEqual(saved.records.count, count - 1)
    }

    func testRemovingFromTheBookRemovesTheItem() {
        var saved = items(TaxSample.make().book)
        let old = saved.book
        var new = old
        new.removeProperty("flat")
        saved.update(from: old, to: new, isPrivatePayment: { _ in false })
        XCTAssertEqual(Set(saved.records.map(\.collection)), ["taxPay"])
    }

    func testARestoredItemGetsTheRightPrivacy() {
        let book = TaxSample.make().book
        let all = items(book, private: ["tax-sample-plumber"])
        var saved = all
        _ = saved.apply(saves: [], deletes: ["taxPayments|tax-sample-plumber", "taxProperties|flat"])
        for key in ["taxPayments|tax-sample-plumber", "taxProperties|flat"] {
            var old = all.records.first { $0.key == key }!
            old.isPrivate = false
            saved.restore(old) { $0 == "tax-sample-plumber" }
        }
        XCTAssertEqual(saved.records, all.records)
    }

    func testTurningAnItemTwiceGivesItBack() {
        var book = TaxSample.make().book
        book.properties[0].myShare = Decimal(string: "0.9")!
        book.figures = [YearFigures(id: "c", person: .me, taxYear: "2025-26", losses: 10, isShared: true)]
        let records = items(book).records
        for record in records {
            XCTAssertEqual(TaxItems.flipped(TaxItems.flipped(record)), record, record.key)
        }
        let turned = TaxItems(records.map(TaxItems.flipped)).book
        XCTAssertEqual(turned.properties[0].myShare, Decimal(string: "0.1"))
        XCTAssertEqual(turned.pay.first { $0.id == "job-me" }?.person, .partner)
        XCTAssertEqual(turned.figures[0].person, .partner)
    }
}
