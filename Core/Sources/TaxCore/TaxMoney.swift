import Foundation

public enum TaxMoney {
    public static func round(_ value: Decimal, scale: Int, _ mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, scale, mode)
        return output
    }

    /// Whole pounds, rounded down: HMRC lets income and tax reliefs round in these directions.
    public static func poundsDown(_ value: Decimal) -> Decimal { round(value, scale: 0, .down) }
    /// Whole pounds, rounded up, for expenses and tax already paid.
    public static func poundsUp(_ value: Decimal) -> Decimal { round(value, scale: 0, .up) }
    public static func penceDown(_ value: Decimal) -> Decimal { round(value, scale: 2, .down) }

    /// Reads what a person types: "1,250.50", "£1250". Nil for anything else, including
    /// negative amounts.
    public static func parse(_ text: String) -> Decimal? {
        let cleaned = text.filter { !" £,".contains($0) }
        guard cleaned.range(of: #"^\d{1,10}(\.\d{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// "£1,234.56" or "-£12.00", the same on every platform whatever its locale.
    public static func format(_ value: Decimal) -> String {
        let rounded = round(value, scale: 2, .plain)
        let negative = rounded < 0
        let parts = "\(negative ? -rounded : rounded)".split(separator: ".")
        var whole = String(parts[0])
        var index = whole.count - 3
        while index > 0 {
            whole.insert(",", at: whole.index(whole.startIndex, offsetBy: index))
            index -= 3
        }
        let pence = parts.count > 1 ? String(parts[1]) : ""
        return (negative ? "-£" : "£") + whole + "." + pence.padding(toLength: 2, withPad: "0", startingAt: 0)
    }
}
