import XCTest
@testable import BudgetCore

final class AccountHolderTests: XCTestCase {
    func testStatementInThePartnersNameIsTheirs() {
        XCTAssertEqual(AccountHolders.owner(holders: ["SHWETA KUMAR"], myName: "Nishant", partnerName: "Shweta"), .partner)
        XCTAssertEqual(AccountHolders.owner(holders: ["NISHANT KUMAR"], myName: "Nishant Kumar", partnerName: "Shweta"), .mine)
        XCTAssertEqual(AccountHolders.owner(holders: ["NISHANT KUMAR", "SHWETA KUMAR"], myName: "Nishant", partnerName: "Shweta"), .shared)
    }

    func testInitialsOnTheStatement() {
        XCTAssertEqual(AccountHolders.owner(holders: ["S KUMAR"], myName: "Nishant", partnerName: "Shweta Kumar"), .partner)
        XCTAssertNil(AccountHolders.owner(holders: ["S KUMAR"], myName: "Sam", partnerName: "Shweta"), "Same initial: can't tell")
    }

    func testWithoutYourNameAnyoneButYourPartnerIsYou() {
        XCTAssertEqual(AccountHolders.owner(holders: ["SHWETA KUMAR"], myName: nil, partnerName: "Shweta"), .partner)
        XCTAssertEqual(AccountHolders.owner(holders: ["NISHANT KUMAR", "SHWETA KUMAR"], myName: "", partnerName: "Shweta"), .shared)
        XCTAssertEqual(AccountHolders.owner(holders: ["NISHANT KUMAR"], myName: nil, partnerName: "Shweta"), .mine)
    }

    func testSomeoneElseOrNobody() {
        XCTAssertNil(AccountHolders.owner(holders: ["JOHN SMITH"], myName: "Nishant", partnerName: "Shweta"))
        XCTAssertNil(AccountHolders.owner(holders: [], myName: "Nishant", partnerName: "Shweta"))
        XCTAssertFalse(AccountHolders.matches(holder: "SHWETA SINGH", person: "Shweta Kumar"), "A different surname is someone else")
        XCTAssertTrue(AccountHolders.matches(holder: "MRS SHWETA KUMAR", person: "shweta"))
    }

    func testHoldersFromTheAddress() {
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["Your HSBC Credit Card statement", "Mrs Shweta Kumar", "1 High Street"]), ["SHWETA KUMAR"])
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["MR N KUMAR & MRS S. KUMAR", "1 High Street"]), ["N KUMAR", "S. KUMAR"])
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["Mr Kumar", "03 Oct DR MARTENS 12.00"]), [], "One word, or a payment line, isn't a holder")
        // The line next to the sort code wins over the address.
        XCTAssertEqual(PDFStatementParser.holderNames(in: ["Mrs Shweta Kumar", "MR NISHANT KUMAR 40-47-60 51385429"]), ["NISHANT KUMAR"])
    }
}
