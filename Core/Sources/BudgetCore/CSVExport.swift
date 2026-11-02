import Foundation

/// Writes transactions as CSV that opens cleanly in Excel or Numbers and can be imported again.
public enum CSVExporter {
    public static let header = ["Date", "Merchant", "Description", "Category", "Amount", "Split of"]

    /// One row per transaction, or one row per split for split transactions (with the
    /// original merchant in "Split of"), so category totals add up in a spreadsheet.
    public static func transactions(_ transactions: [BankTransaction], calendar: Calendar = .current) -> String {
        var rows = [header]
        for transaction in transactions.sorted(by: { $0.date < $1.date }) {
            let day = isoDay(transaction.date, calendar: calendar)
            if transaction.splits.isEmpty {
                rows.append([day, transaction.merchant, transaction.description, transaction.category, "\(transaction.amount)", ""])
            } else {
                let sign: Decimal = transaction.amount < 0 ? -1 : 1
                for split in transaction.splits {
                    rows.append([day, split.label, transaction.description, split.category, "\(split.amount * sign)", transaction.merchant])
                }
            }
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ field: String) -> String {
        // A leading = + - @ makes spreadsheets run the cell as a formula; neutralise it.
        var value = field
        if let first = value.first, "=+@".contains(first) || (first == "-" && AmountParser.parse(value, decimalComma: false) == nil) {
            value = "'" + value
        }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func isoDay(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
