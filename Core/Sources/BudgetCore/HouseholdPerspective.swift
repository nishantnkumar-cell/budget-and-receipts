import Foundation

/// Shared household data is stored from the owner's point of view: "mine" is the person who
/// created the household and "partner" is the person they invited. A partner's app turns it
/// round as it arrives and back as it leaves, so on each phone "Mine" means you.
public enum HouseholdPerspective {
    /// The same record seen from the other person's side. Turning it twice gives it back.
    public static func flipped(_ record: SyncRecord) -> SyncRecord {
        var result = record
        switch record.collection {
        case "transactions": result.payload = flip(record.payload, as: BankTransaction.self, flipTransaction)
        case "accounts": result.payload = flip(record.payload, as: BankAccount.self) { $0.owner = $0.owner.map(flip) }
        case "pendingReceipts": result.payload = flip(record.payload, as: PendingReceipt.self) { receipt in
            for index in receipt.editor.items.indices { receipt.editor.items[index].owner = receipt.editor.items[index].owner.map(flip) }
        }
        case "wealth": result.payload = flip(record.payload, as: WealthAccount.self) { $0.owner = $0.owner.map(flip) }
        case "notes": result.payload = flip(record.payload, as: TransactionNote.self) { $0.author = $0.author.other }
        case "settlements": result.payload = flip(record.payload, as: Settlement.self) { $0.from = $0.from.other }
        case "couple": result.payload = flip(record.payload, as: CoupleSettings.self, flipCouple)
        default: break
        }
        return result
    }

    public static func flip(_ owner: MoneyOwner) -> MoneyOwner {
        switch owner {
        case .mine: .partner
        case .partner: .mine
        case .shared: .shared
        }
    }

    static func flipTransaction(_ transaction: inout BankTransaction) {
        transaction.owner = transaction.owner.map(flip)
        transaction.paidBy = transaction.paidBy.map(\.other)
        for index in transaction.splits.indices { transaction.splits[index].owner = transaction.splits[index].owner.map(flip) }
        if var draft = transaction.pendingSplitDraft {
            for index in draft.proposedSplits.indices { draft.proposedSplits[index].owner = draft.proposedSplits[index].owner.map(flip) }
            for index in draft.receipt.items.indices { draft.receipt.items[index].owner = draft.receipt.items[index].owner.map(flip) }
            transaction.pendingSplitDraft = draft
        }
    }

    static func flipCouple(_ couple: inout CoupleSettings) {
        let partner = couple.partnerName
        couple.partnerName = couple.ownerName ?? ""
        couple.ownerName = partner
        couple.myShare = 1 - couple.myShare
        couple.defaultOwner = flip(couple.defaultOwner)
        for index in couple.rules.indices { couple.rules[index].owner = flip(couple.rules[index].owner) }
    }

    private static func flip<T: Codable>(_ payload: Data, as type: T.Type, _ change: (inout T) -> Void) -> Data {
        guard var value = try? SyncRecord.decoder().decode(T.self, from: payload),
              let data = { change(&value); return try? SyncRecord.encoder().encode(value) }() else { return payload }
        return data
    }
}
