import Foundation

/// Works out whose account a statement is from, by matching the account holders printed on it
/// against the names in Settings > Couple ("Your name" and "Partner's name").
public enum AccountHolders {
    /// The owner the holders point to: only you is mine, only your partner is theirs, both of you
    /// is a joint (shared) account. Nil when the statement names nobody, or nobody it can tell apart.
    /// - Parameters:
    ///   - holders: names as the statement prints them, e.g. ["SARA PATEL"] or ["MRS S PATEL"].
    ///   - myName: your name from Settings; a first name alone is enough. Without it, a holder
    ///     who isn't your partner is taken to be you, so a joint account still reads as joint.
    ///   - partnerName: your partner's name from Settings; empty for a single-person budget.
    public static func owner(holders: [String], myName: String?, partnerName: String) -> MoneyOwner? {
        var me = false, partner = false
        let knowMyName = !words(myName ?? "").isEmpty
        for holder in holders {
            let isPartner = matches(holder: holder, person: partnerName)
            let isMe = knowMyName ? matches(holder: holder, person: myName ?? "") : !isPartner
            // A holder that could be either of you (e.g. the same initial) says nothing.
            if isMe && isPartner { continue }
            me = me || isMe
            partner = partner || isPartner
        }
        switch (me, partner) {
        case (true, true): return .shared
        case (true, false): return .mine
        case (false, true): return .partner
        case (false, false): return nil
        }
    }

    /// Whether a statement holder is this person. The first names must agree (an initial on the
    /// statement counts), and when Settings has a surname too, the surnames must agree.
    public static func matches(holder: String, person: String) -> Bool {
        let holderWords = words(holder)
        let personWords = words(person)
        guard let holderFirst = holderWords.first, let personFirst = personWords.first else { return false }
        let firstAgrees = holderFirst.count == 1 || personFirst.count == 1
            ? holderFirst.first == personFirst.first
            : holderFirst == personFirst
        guard firstAgrees else { return false }
        if personWords.count >= 2, holderWords.count >= 2 {
            return holderWords.last == personWords.last
        }
        return true
    }

    /// Upper-case words of letters only, without titles such as Mr or Mrs.
    static func words(_ name: String) -> [String] {
        let titles: Set<String> = ["MR", "MRS", "MS", "MISS", "DR", "MX"]
        return name.uppercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty && !titles.contains($0) }
    }
}
