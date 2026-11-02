import BudgetCore
import SwiftUI

extension MoneyOwner {
    /// "Mine", the partner's name, or "Shared".
    func label(partnerName: String) -> String {
        switch self {
        case .mine: "Mine"
        case .partner: partnerName.isEmpty ? "Partner" : partnerName
        case .shared: "Shared"
        }
    }
}

/// Whose money one item is. "Automatic" follows the transaction and the couple rules.
struct OwnerPicker: View {
    @EnvironmentObject var store: BudgetStore
    @Binding var owner: MoneyOwner?

    var body: some View {
        Picker("Whose", selection: $owner) {
            Text("Automatic").tag(MoneyOwner?.none)
            ForEach(MoneyOwner.allCases, id: \.self) { owner in
                Text(owner.label(partnerName: store.couple.partnerName)).tag(MoneyOwner?.some(owner))
            }
        }
    }
}

/// Settings for a couple: the partner, how shared costs split, and the Mine / Partner / Shared rules.
struct CoupleSettingsSection: View {
    @EnvironmentObject var store: BudgetStore
    @State private var newMerchant = ""

    private var settings: Binding<CoupleSettings> {
        Binding(get: { store.couple }, set: { store.updateCouple($0) })
    }

    private var myPercent: Binding<Int> {
        Binding(
            get: { NSDecimalNumber(decimal: store.couple.myShare * 100).intValue },
            set: { settings.wrappedValue.myShare = Decimal($0) / 100 }
        )
    }

    var body: some View {
        Section {
            TextField("Partner's name", text: settings.partnerName, prompt: Text("Leave empty if it's just you"))
            if store.hasPartner {
                Stepper("Your share of shared costs: \(myPercent.wrappedValue)%", value: myPercent, in: 0...100, step: 5)
                Picker("Anything else is", selection: settings.defaultOwner) {
                    ForEach(MoneyOwner.allCases, id: \.self) { Text($0.label(partnerName: store.couple.partnerName)).tag($0) }
                }
            }
        } header: {
            Text("Couple")
        } footer: {
            Text(store.hasPartner
                 ? "Shared costs count \(myPercent.wrappedValue)% to you and \(100 - myPercent.wrappedValue)% to \(store.couple.partnerName). Whoever pays is owed the other person's part."
                 : "Add a partner to split shared costs and see who owes whom.")
        }
        if store.hasPartner {
            Section {
                ForEach(settings.rules) { $rule in
                    Picker(ruleTitle(rule), selection: $rule.owner) {
                        ForEach(MoneyOwner.allCases, id: \.self) { Text($0.label(partnerName: store.couple.partnerName)).tag($0) }
                    }
                }
                .onDelete { settings.wrappedValue.rules.remove(atOffsets: $0) }
                HStack {
                    TextField("Merchant name contains…", text: $newMerchant)
                    Button("Add") {
                        settings.wrappedValue.rules.append(OwnerRule(match: .merchant(newMerchant), owner: .shared))
                        newMerchant = ""
                    }
                    .disabled(newMerchant.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Menu("Add Category Rule") {
                    ForEach(FinanceCategories.budgetable, id: \.self) { category in
                        Button(category) { settings.wrappedValue.rules.append(OwnerRule(match: .category(category), owner: .shared)) }
                    }
                }
            } header: {
                Text("Whose money rules")
            } footer: {
                Text("Merchant rules win over category rules. Anything you set by hand on a transaction or receipt item wins over both.")
            }
            Section("Who owes whom") {
                let balance = store.coupleBalance
                switch balance.debtor {
                case .partner: LabeledContent("\(store.couple.partnerName) owes you", value: balance.amountOwed.formatted(.currency(code: AppSettings.currency)))
                case .me: LabeledContent("You owe \(store.couple.partnerName)", value: balance.amountOwed.formatted(.currency(code: AppSettings.currency)))
                case nil: Text("You're all square.")
                }
                if balance.debtor != nil {
                    Button("Mark as Settled Up") { store.settleUp() }
                }
            }
        }
    }

    private func ruleTitle(_ rule: OwnerRule) -> String {
        switch rule.match {
        case .merchant(let text): "Merchant: \(text)"
        case .category(let category): category
        }
    }
}
