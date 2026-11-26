import BudgetCore
import Foundation

/// The property book as separate synced items, one for each thing entered, so two devices (or a
/// couple) changing different things never overwrite each other. Items are held from this
/// person's point of view.
public struct TaxItems: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case property = "taxProperties", rule = "taxRules", payment = "taxPayments", statement = "taxStatements"
        case interest = "taxInterest", pay = "taxPay", figures = "taxFigures"
    }

    public static let collections = Set(Kind.allCases.map(\.rawValue))

    private var byKey: [String: SyncRecord]

    public init(_ records: [SyncRecord] = []) {
        byKey = Dictionary(records.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// In a fixed order, so the same items are saved the same way.
    public var records: [SyncRecord] { byKey.values.sorted { $0.key < $1.key } }
    public var isEmpty: Bool { byKey.isEmpty }

    /// What the items say. One this version can't read is kept but not shown.
    public var book: PropertyBook {
        let decoder = SyncRecord.decoder()
        func all<T: Decodable>(_ kind: Kind) -> [T] {
            records.filter { $0.collection == kind.rawValue }.compactMap { try? decoder.decode(T.self, from: $0.payload) }
        }
        let properties: [RentalProperty] = all(.property)
        let rules: [PropertyRule] = all(.rule)
        let statements: [AgentStatement] = all(.statement)
        let pay: [TaxPay] = all(.pay)
        return PropertyBook(
            properties: properties.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) },
            rules: rules.sorted { $0.added != $1.added ? $0.added > $1.added : $0.id < $1.id },
            assignments: all(.payment),
            statements: statements.sorted { ($0.date, $0.id) < ($1.date, $1.id) },
            interest: all(.interest),
            pay: pay.sorted { ($0.employer.lowercased(), $0.id) < ($1.employer.lowercased(), $1.id) },
            figures: all(.figures))
    }

    public var unreadableCount: Int {
        let book = book
        return records.count - Self.records(for: book, isPrivatePayment: { _ in false }).count
    }

    /// One record per item. An item about a payment kept from the partner is private too, and
    /// so is one whose payment isn't here to ask about (`nil`).
    static func records(for book: PropertyBook, isPrivatePayment: (String) -> Bool?) -> [SyncRecord] {
        func make<T: Encodable & Identifiable>(_ items: [T], _ kind: Kind, isPrivate: (T) -> Bool = { _ in false }) -> [SyncRecord]
        where T.ID == String {
            SyncRecord.records(items, collection: kind.rawValue, id: \.id, isPrivate: isPrivate)
        }
        return make(book.properties, .property)
            + make(book.rules, .rule, isPrivate: \.isPrivate)
            + make(book.assignments, .payment, isPrivate: { isPrivatePayment($0.fingerprint) ?? true })
            + make(book.statements, .statement, isPrivate: { $0.bankFingerprint.map { isPrivatePayment($0) ?? true } ?? false })
            + make(book.interest, .interest)
            + make(book.pay, .pay, isPrivate: { !$0.isShared })
            + make(book.figures, .figures, isPrivate: { !$0.isShared })
    }

    /// Saves what the person changed. Items they didn't touch stay exactly as stored,
    /// including anything a newer version added to them.
    public mutating func update(from old: PropertyBook, to new: PropertyBook, isPrivatePayment: (String) -> Bool?) {
        func index(_ book: PropertyBook) -> [String: SyncRecord] {
            Dictionary(Self.records(for: book, isPrivatePayment: isPrivatePayment).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        }
        let before = index(old), after = index(new)
        for key in before.keys where after[key] == nil { byKey[key] = nil }
        for (key, record) in after where before[key] != record {
            var record = record
            // The payment isn't here to ask about: keep who could see the item before.
            if let stored = byKey[key], let fingerprint = Self.fingerprint(of: record), isPrivatePayment(fingerprint) == nil {
                record.isPrivate = stored.isPrivate
            }
            byKey[key] = record
        }
    }

    /// The payment an item is about, when it is about one.
    private static func fingerprint(of record: SyncRecord) -> String? {
        let decoder = SyncRecord.decoder()
        return switch Kind(rawValue: record.collection) {
        case .payment: (try? decoder.decode(TaxAssignment.self, from: record.payload))?.fingerprint
        case .statement: (try? decoder.decode(AgentStatement.self, from: record.payload))?.bankFingerprint
        default: nil
        }
    }

    /// You changed who can see these payments: their items follow. This is the only way an
    /// item about a payment goes from private to shared.
    public mutating func followPrivacy(of fingerprints: Set<String>, isPrivatePayment: (String) -> Bool?) {
        for (key, record) in byKey {
            guard let fingerprint = Self.fingerprint(of: record), fingerprints.contains(fingerprint),
                  let isPrivate = isPrivatePayment(fingerprint) else { continue }
            byKey[key]?.isPrivate = isPrivate
        }
    }

    /// Takes in what arrived from your other devices or your partner.
    public mutating func apply(saves: [SyncRecord], deletes: Set<String>) -> Bool {
        let before = byKey
        for key in deletes { byKey[key] = nil }
        for record in saves where Self.collections.contains(record.collection) {
            var record = record
            record.byPartner = false
            byKey[record.key] = record
        }
        return byKey != before
    }

    /// Puts an earlier version of an item back, with the privacy its contents call for.
    public mutating func restore(_ record: SyncRecord, isPrivatePayment: (String) -> Bool?) {
        let restored = Self.records(for: Self([record]).book, isPrivatePayment: isPrivatePayment)
        var record = record
        record.isPrivate = restored.first { $0.key == record.key }?.isPrivate ?? record.isPrivate
        byKey[record.key] = record
    }

    /// The items to send. One about a payment that is private now goes privately at once; one
    /// held as private stays so until you change the payment (see `followPrivacy`), so a
    /// device that hasn't caught up can't share it.
    public func syncRecords(privacy: (String) -> Bool?) -> [SyncRecord] {
        records.map { record in
            var record = record
            if let fingerprint = Self.fingerprint(of: record), privacy(fingerprint) == true { record.isPrivate = true }
            return record
        }
    }

    /// True when this item was typed in by the person using this device, so a partner's
    /// change to it is turned down.
    public func isMyOwnEntry(_ key: String) -> Bool {
        guard let record = byKey[key] else { return false }
        let decoder = SyncRecord.decoder()
        return switch Kind(rawValue: record.collection) {
        case .pay: (try? decoder.decode(TaxPay.self, from: record.payload))?.enteredBy == .me
        case .figures: (try? decoder.decode(YearFigures.self, from: record.payload))?.enteredBy == .me
        default: false
        }
    }

    /// The same item seen from the other person's side of a shared household: "me" and
    /// "partner" swap. Turning it twice gives it back.
    public static func flipped(_ record: SyncRecord) -> SyncRecord {
        func change<T: Codable>(_ type: T.Type, _ turn: (inout T) -> Void) -> SyncRecord {
            guard var value = try? SyncRecord.decoder().decode(T.self, from: record.payload) else { return record }
            turn(&value)
            guard let payload = try? SyncRecord.encoder().encode(value) else { return record }
            var result = record
            result.payload = payload
            return result
        }
        return switch Kind(rawValue: record.collection) {
        case .property: change(RentalProperty.self) { $0.myShare = 1 - $0.myShare }
        case .pay: change(TaxPay.self) { $0.person = $0.person.other; $0.enteredBy = $0.enteredBy.other }
        case .figures: change(YearFigures.self) { $0.person = $0.person.other; $0.enteredBy = $0.enteredBy.other }
        default: record
        }
    }
}
