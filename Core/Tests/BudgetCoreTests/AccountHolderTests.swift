import XCTest
@testable import BudgetCore

final class AccountHolderTests: XCTestCase {
    func testStatementInThePartnersNameIsTheirs() {
        XCTAssertEqual(AccountHolders.owner(holders: ["SARA PATEL"], myName: "Neil", partnerName: "Sara"), .partner)
        XCTAssertEqual(AccountHolders.owner(holders: ["NEIL PATEL"], myName: "Neil Patel", partnerName: "Sara"), .mine)
        XCTAssertEqual(AccountHolders.owner(holders: ["NEIL PATEL", "SARA PATEL"], myName: "Neil", partnerName: "Sara"), .shared)
    }

    func testInitialsOnTheStatement() {
        XCTAssertEqual(AccountHolders.owner(holders: ["S PATEL"], myName: "Neil", partnerName: "Sara Patel"), .partner)
        XCTAssertNil(AccountHolders.owner(holders: ["S PATEL"], myName: "Sam", partnerName: "Sara"), "Same initial: can't tell")
    }

    func testWithoutYourNameAnyoneButYourPartnerIsYou() {
        XCTAssertEqual(AccountHolders.owner(holders: ["SARA PATEL"], myName: nil, partnerName: "Sara"), .partner)
        XCTAssertEqual(AccountHolders.owner(holders: ["NEIL PATEL", "SARA PATEL"], myName: "", partnerName: "Sara"), .shared)
        XCTAssertEqual(AccountHolders.owner(holders: ["NEIL PATEL"], myName: nil, partnerName: "Sara"), .mine)
    }

    func testSomeoneElseOrNobody() {
        XCTAssertNil(AccountHolders.owner(holders: ["JOHN SMITH"], myName: "Neil", partnerName: "Sara"))
        XCTAssertNil(AccountHolders.owner(holders: [], myName: "Neil", partnerName: "Sara"))
        XCTAssertFalse(AccountHolders.matches(holder: "SARA SINGH", person: "Sara Patel"), "A different surname is someone else")
        XCTAssertTrue(AccountHolders.matches(holder: "MRS SARA PATEL", person: "sara"))
    }

    func testHoldersFromTheAddress() {
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["Your HSBC Credit Card statement", "Mrs Sara Patel", "1 High Street"]), ["SARA PATEL"])
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["MR N PATEL & MRS S. PATEL", "1 High Street"]), ["N PATEL", "S. PATEL"])
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["Mr Patel", "03 Oct DR MARTENS 12.00"]), [], "One word, or a payment line, isn't a holder")
        // The line next to the sort code wins over the address.
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["Mrs Sara Patel", "MR NEIL PATEL 11-22-33 11112222"]), ["NEIL PATEL"])
    }
}
