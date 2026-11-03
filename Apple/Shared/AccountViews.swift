import BudgetCore
import SwiftUI

/// Picks which account a transaction or statement belongs to.
struct AccountPicker: View {
    @EnvironmentObject var store: BudgetStore
    var title = "Account"
    @Binding var selection: UUID?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("No account").tag(UUID?.none)
            ForEach(store.accounts) { Text($0.label).tag(UUID?.some($0.id)) }
        }
    }
}

/// Toolbar menu to show one account's money only. Hidden until there are two accounts.
struct AccountFilterMenu: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        if store.accounts.count > 1 {
            Menu {
                Picker("Account", selection: $store.accountFilter) {
                    Text("All accounts").tag(UUID?.none)
                    ForEach(store.accounts) { Text($0.label).tag(UUID?.some($0.id)) }
                }
            } label: {
                Label(store.account(store.accountFilter)?.name ?? "All accounts",
                      systemImage: store.accountFilter == nil ? "building.columns" : "building.columns.fill")
            }
            .accessibilityLabel("Show account")
        }
    }
}

/// This month's spending per account. Shown once statements come from more than one account.
struct AccountSpendingCard: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        let rows = store.spendingByAccount
        if !store.selectedMonthIsEmpty, rows.filter({ $0.account != nil }).count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("Spending by account")
                ForEach(rows, id: \.account?.id) { row in
                    Button {
                        store.accountFilter = store.accountFilter == row.account?.id ? nil : row.account?.id
                    } label: {
                        HStack {
                            Text(row.account?.label ?? "No account")
                                .fontWeight(store.accountFilter != nil && store.accountFilter == row.account?.id ? .semibold : .regular)
                            Spacer()
                            Text(row.spent.money).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(row.account == nil)
                }
            }
            .card()
        }
    }
}

/// Settings: name accounts and the cards that pay from them.
struct AccountsSettingsSection: View {
    @EnvironmentObject var store: BudgetStore
    @State private var newName = ""

    var body: some View {
        Section {
            ForEach(store.accounts) { account in
                NavigationLink { AccountEditor(account: account) } label: {
                    HStack(spacing: 12) {
                        IconBadge(systemImage: account.isPrivate == true ? "lock" : "building.columns", size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.label).lineLimit(1)
                            if !account.cardEndings.isEmpty {
                                Text("Cards ••" + account.cardEndings.joined(separator: ", ••")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if store.hasPartner {
                            OwnerChip(owner: account.owner ?? .mine, partnerName: store.couple.partnerName)
                        }
                    }
                }
            }
            HStack {
                TextField("New account name", text: $newName)
                Button("Add") {
                    store.addAccount(name: newName.trimmingCharacters(in: .whitespaces))
                    newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Bank accounts")
        } footer: {
            Text("Accounts are added when a statement includes its account number. Name them here, and add your card endings so receipts are matched to the right account.")
        }
    }
}

struct AccountEditor: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State var account: BankAccount
    @State private var cards = ""
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            TextField("Name", text: $account.name, prompt: Text("e.g. Joint current account"))
            TextField("Account number (last 4 digits are enough)", text: $account.number)
            Section {
                Picker("Whose account", selection: Binding(get: { account.owner ?? .mine }, set: { account.owner = $0 })) {
                    Text("Mine").tag(MoneyOwner.mine)
                    Text(store.couple.partnerName.isEmpty ? "Partner's" : "\(store.couple.partnerName)'s").tag(MoneyOwner.partner)
                    Text("Joint").tag(MoneyOwner.shared)
                }
            } footer: {
                if store.hasPartner, let owner = account.owner {
                    Text("Payments from this account count as \(owner.label(partnerName: store.couple.partnerName)) unless you change one.")
                }
            }
            PrivateToggle(isPrivate: $account.isPrivate, footer: "Its transactions are private too.")
            Section {
                TextField("Card endings, e.g. 1234, 5678", text: $cards)
            } footer: {
                Text("The last four digits printed on receipts paid with cards from this account.")
            }
            Section {
                Button("Delete Account", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("Its transactions are kept, without an account.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(account.name.isEmpty ? "Account" : account.name)
        .onAppear { cards = account.cardEndings.joined(separator: ", ") }
        .onDisappear(perform: save)
        .alert("Delete \(account.label)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.deleteAccount(account)
                dismiss()
            }
        }
    }

    private func save() {
        guard store.accounts.contains(where: { $0.id == account.id }) else { return }
        account.cardEndings = cards.split(whereSeparator: { !$0.isNumber }).map { String($0.suffix(4)) }.filter { $0.count == 4 }
        account.name = account.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Account" : account.name
        store.updateAccount(account)
    }
}

/// Marks an item private: hidden from a partner you share the household with. Shared by default.
struct PrivateToggle: View {
    @Binding var isPrivate: Bool?
    var footer = "Hidden from your partner when you share your household."

    var body: some View {
        Toggle(isOn: Binding(get: { isPrivate == true }, set: { isPrivate = $0 ? true : nil })) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Private", systemImage: "lock")
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
