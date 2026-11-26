import Foundation

/// A UK tax year, 6 April to 5 April, judged by the date in London.
public struct TaxYear: Hashable, Sendable, CustomStringConvertible {
    public let startYear: Int

    /// Only years whose rules have been entered and checked. Property income rates change from
    /// April 2027, so later years are refused rather than worked out with old rates.
    public static let supported = [TaxYear(startYear: 2025), TaxYear(startYear: 2026)]

    public init(startYear: Int) { self.startYear = startYear }

    /// Reads "2025-26". Nil for anything else, including years that aren't supported.
    public init?(_ text: String) {
        guard let year = Self.supported.first(where: { $0.description == text }) else { return nil }
        self = year
    }

    public var description: String {
        let end = (startYear + 1) % 100
        return "\(startYear)-\(end < 10 ? "0" : "")\(end)"
    }

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    public static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public var start: Date { Self.day(startYear, 4, 6) }
    /// The first moment after the year.
    public var end: Date { Self.day(startYear + 1, 4, 6) }
    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}
