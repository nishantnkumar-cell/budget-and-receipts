import BudgetCore
import Foundation

/// Made-up rupee accounts for screenshots, previews and tests.
public enum IndiaSample {
    /// An SBI statement as downloaded: headings, then tab-separated columns.
    public static let sbiStatement = [
        "Account Name\t: SAMPLE PERSON",
        "Account Number\t:_00000000000004321",
        "",
        "Txn Date\tValue Date\tDescription\tRef No./Cheque No.\tDebit\tCredit\tBalance",
        "1 Apr 2026\t1 Apr 2026\tBY TRANSFER-NEFT SAMPLE RENT\tREF1\t \t25,000.00\t1,25,000.00",
        "10 Apr 2026\t10 Apr 2026\tTO TRANSFER-UPI SAMPLE SOCIETY\tREF2\t4,500.00\t \t1,20,500.00",
        "30 Jun 2026\t30 Jun 2026\tCREDIT INTEREST--\t\t \t1,200.00\t1,21,700.00",
        "30 Jun 2026\t30 Jun 2026\tTDS ON INTEREST\t\t360.00\t \t1,21,340.00",
        "**This is a computer generated statement"
    ].joined(separator: "\n")

    /// An ICICI statement saved as CSV.
    public static let iciciStatement = """
    DETAILED STATEMENT,,,,,,,
    Account Number,XXXXXXXX8765,,,,,,
    ,,,,,,,
    S No.,Value Date,Transaction Date,Cheque Number,Transaction Remarks,Withdrawal Amount (INR ),Deposit Amount (INR ),Balance (INR )
    1,05/04/2026,05/04/2026,-,UPI/SAMPLE TRANSFER FROM UK,0.00,"2,00,000.00","5,00,000.00"
    2,12/05/2026,12/05/2026,-,ATM/SAMPLE CASH,"10,000.00",0.00,"4,90,000.00"
    3,30/06/2026,30/06/2026,-,XXXXXXXX8765:Int.Pd:31-03-2026 to 29-06-2026,0.00,"3,650.00","4,93,650.00"
    """

    public static func make() -> IndiaBook {
        var book = IndiaBook()
        let sbi = IndiaAccount(id: "india-sample-sbi", bank: .sbi, kind: .nro, lastFour: "4321", owner: .shared)
        let icici = IndiaAccount(id: "india-sample-icici", bank: .icici, kind: .nre, lastFour: "8765")
        let deposit = IndiaAccount(id: "india-sample-deposit", bank: .sbi, kind: .deposit, lastFour: "2468",
                                   owner: .partner, statedBalance: 300_000, statedOn: TaxYear.day(2026, 4, 1))
        book.accounts = [sbi, icici, deposit]
        for (account, text) in [(sbi, sbiStatement), (icici, iciciStatement)] {
            guard let statement = try? IndiaStatement.read(text: text) else { continue }
            book.entries += statement.entries(for: account.id, existing: []).new
        }
        var certificate = IndiaEntry.manual(accountID: deposit.id, date: TaxYear.day(2026, 6, 30), kind: .interest, rupees: 5_250)
        certificate.id = "manual|india-sample"
        book.entries.append(certificate)
        book.setRate("2026-27", rupeesPerPound: 115)
        book.setRate(IndiaRate.balancesID, rupeesPerPound: 118)
        return book
    }
}
