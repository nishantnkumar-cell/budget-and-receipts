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
        XCTAssertEqual(record("taxRules", "sample bank mortgage")?.isPrivate, true)
        XCTAssertEqual(record("taxProperties", "flat")?.isPrivate, false)
    }

    func testPrivacyFollowsThePaymentNowAndStaysWhenThePaymentIsElsewhere() {
        let saved = items(TaxSample.make().book, private: ["tax-sample-plumber"])
        func plumber(_ privacy: Bool?) -> Bool? {
            saved.syncRecords { $0 == "tax-sample-plumber" ? privacy : nil }
                .first { $0.key == "taxPayments|tax-sample-plumber" }?.isPrivate
        }
        XCTAssertEqual(plumber(false), false)
        XCTAssertEqual(plumber(nil), true)
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
        book.carried = [CarriedForward(id: "c", person: .me, taxYear: "2025-26", losses: 10, isShared: true)]
        let records = items(book).records
        for record in records {
            XCTAssertEqual(TaxItems.flipped(TaxItems.flipped(record)), record, record.key)
        }
        let turned = TaxItems(records.map(TaxItems.flipped)).book
        XCTAssertEqual(turned.properties[0].myShare, Decimal(string: "0.1"))
        XCTAssertEqual(turned.pay.first { $0.id == "job-me" }?.person, .partner)
        XCTAssertEqual(turned.carried[0].person, .partner)
    }
}
