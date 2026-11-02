import Foundation

/// Exact money values for tests. A Swift literal such as `3.69` passed as a Decimal goes
/// through Double first and becomes 3.690000000000000512, which hides rounding bugs.
func money(_ value: String) -> Decimal { Decimal(string: value)! }
