import BudgetCore
import SwiftUI
import TaxCore

/// India Accounts: rupee balances, and the way to statements and interest.
struct IndiaHomeView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var india: IndiaStore
    @State private var adding: IndiaAccount?

    var body: some View {
        let accounts = india.book.accounts
        let total = india.book.totalBalance(accounts)
        Form {
            Section {
                ForEach(accounts) { account in
                    NavigationLink { IndiaAccountView(accountID: account.id) } label: { IndiaAccountRow(account: account) }
                }
                Button("Add Account", systemImage: "plus") { adding = IndiaAccount(bank: .icici, kind: .nro) }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Rupees stay here. They're never added to your pound budgets, net worth or tax estimate.")
            }
            if !accounts.isEmpty {
                Section {
                    IndiaAmountRow(title: "All balances", rupees: total, rate: india.book.rate(IndiaRate.balancesID))
                }
                Section {
                    NavigationLink { IndiaImportView() } label: { Label("Import Statement", systemImage: "square.and.arrow.down") }
                    NavigationLink { IndiaReportView() } label: { Label("Interest for UK Tax", systemImage: "doc.text") }
                    NavigationLink { IndiaRatesView() } label: { Label("Exchange Rates", systemImage: "arrow.left.arrow.right") }
                }
            }
            if india.unreadableCount > 0 {
                Section {
                    Label("\(india.unreadableCount) items can't be read, probably saved by a newer version. Update the app on this device.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppSection.india.rawValue)
        .sheet(item: $adding) { IndiaAccountEditor(account: $0, isNew: true) }
    }
}

extension BudgetStore {
    /// Whose an account is, in the household's names.
    func indiaOwnerName(_ owner: MoneyOwner) -> String {
        switch owner {
        case .mine: "Yours"
        case .partner: hasPartner && !couple.partnerName.isEmpty ? "\(couple.partnerName)’s" : "Spouse’s"
        case .shared: "Joint"
        }
    }
}

struct IndiaAccountRow: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var india: IndiaStore
    let account: IndiaAccount

    var body: some View {
        let balance = india.book.balance(of: account.id)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title)
                Text(store.indiaOwnerName(account.owner) + (account.isPrivate ? " · Private" : "")
                     + (balance.map { " · at \(PropertyLedger.day($0.date))" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(balance.map { IndiaMoney.format($0.rupees) } ?? "No balance").monospacedDigit()
        }
    }
}

/// Rupees, with pounds beside them when there's a rate.
struct IndiaAmountRow: View {
    let title: String
    let rupees: Decimal
    let rate: Decimal?

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing) {
                Text(IndiaMoney.format(rupees)).monospacedDigit()
                if let pounds = IndiaMoney.pounds(rupees, rupeesPerPound: rate) {
                    Text("about \(TaxMoney.format(pounds))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

struct IndiaAmountField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text("0.00"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(text.isEmpty || IndiaMoney.parse(text) != nil ? Color.primary : Color.red)
                .accessibilityIdentifier(title)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
    }
}

struct IndiaAccountView: View {
    @EnvironmentObject var india: IndiaStore
    let accountID: String
    @State private var editingAccount: IndiaAccount?
    @State private var editingLine: IndiaEntry?
    @State private var adding = false
    @State private var onlyInterest = false

    var body: some View {
        Form {
            if let account = india.book.account(accountID) {
                let all = india.book.entries(of: accountID)
                let shown = onlyInterest ? all.filter { $0.kind != .other } : all
                Section {
                    if let balance = india.book.balance(of: accountID) {
                        IndiaAmountRow(title: "Balance at \(PropertyLedger.day(balance.date))", rupees: balance.rupees,
                                       rate: india.book.rate(IndiaRate.balancesID))
                    }
                    Button("Edit Account", systemImage: "pencil") { editingAccount = account }
                    Button("Add Interest or Tax", systemImage: "plus") { adding = true }
                }
                Section {
                    Toggle("Only interest and tax", isOn: $onlyInterest)
                    ForEach(shown) { line in
                        Button { editingLine = line } label: { row(line).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                    }
                    if shown.isEmpty { Text("Nothing here yet.").foregroundStyle(.secondary) }
                } header: {
                    Text("Lines")
                } footer: {
                    Text("Interest and tax deducted are picked out from the bank's wording. Choose a line to correct it.")
                }
            } else {
                Text("This account has been removed.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(india.book.account(accountID)?.title ?? "Account")
        .sheet(item: $editingAccount) { IndiaAccountEditor(account: $0, isNew: false) }
        .sheet(item: $editingLine) { IndiaLineEditor(line: $0) }
        .sheet(isPresented: $adding) { IndiaManualEditor(accountID: accountID) }
    }

    private func row(_ line: IndiaEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.narration).lineLimit(2)
                Text(PropertyLedger.day(line.date) + (line.kind == .other ? "" : " · \(line.kind.title)") + (line.isManual ? " · Typed in" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(IndiaMoney.format(line.amount))
                .monospacedDigit()
                .foregroundStyle(line.amount > 0 ? Color.green : Color.primary)
        }
    }
}

struct IndiaAccountEditor: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var india: IndiaStore
    let account: IndiaAccount
    let isNew: Bool
    var saved: (IndiaAccount) -> Void = { _ in }
    @State private var draft: IndiaAccount
    @State private var balance: String
    @State private var balanceDate: Date

    init(account: IndiaAccount, isNew: Bool, saved: @escaping (IndiaAccount) -> Void = { _ in }) {
        self.account = account
        self.isNew = isNew
        self.saved = saved
        _draft = State(initialValue: account)
        _balance = State(initialValue: account.statedBalance.map { "\($0)" } ?? "")
        _balanceDate = State(initialValue: account.statedOn ?? Date())
    }

    private var canSave: Bool {
        balance.isEmpty || IndiaMoney.parse(balance) != nil
    }

    var body: some View {
        TaxSheet(title: isNew ? "New Account" : "Account", canSave: canSave, save: save) {
            Section {
                Picker("Bank", selection: $draft.bank) {
                    ForEach(IndiaBank.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Kind", selection: $draft.kind) {
                    ForEach(IndiaAccount.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Last four digits", text: Binding(get: { draft.lastFour }, set: { draft.lastFour = String($0.filter(\.isNumber).suffix(4)) }))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                TextField("Name (optional)", text: $draft.nickname)
                Picker("Whose", selection: $draft.owner) {
                    ForEach(MoneyOwner.allCases, id: \.self) { Text(store.indiaOwnerName($0)).tag($0) }
                }
                Toggle("Private", isOn: $draft.isPrivate)
            } footer: {
                Text("A joint account's interest is split equally. A private account and its lines aren't shared with your partner.")
            }
            Section {
                IndiaAmountField(title: "Balance (₹)", text: $balance)
                if !balance.isEmpty {
                    DatePicker("On", selection: $balanceDate, displayedComponents: .date)
                }
            } footer: {
                Text("Only for an account without statements, such as a deposit. A newer statement replaces it.")
            }
            if !isNew {
                TaxRemoveButton(title: "Remove Account",
                                warning: "Its lines are removed too, on every device. iCloud may ask you to confirm in Settings.") {
                    india.change { $0.deleteAccount(account.id) }
                }
            }
        }
    }

    private func save() {
        var result = draft
        result.nickname = result.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        result.statedBalance = IndiaMoney.parse(balance)
        result.statedOn = result.statedBalance == nil ? nil : balanceDate
        india.change { $0.save(result) }
        saved(result)
    }
}

private struct IndiaLineEditor: View {
    @EnvironmentObject var india: IndiaStore
    let line: IndiaEntry
    @State private var kind: IndiaEntry.Kind?

    init(line: IndiaEntry) {
        self.line = line
        _kind = State(initialValue: line.chosenKind)
    }

    var body: some View {
        TaxSheet(title: "Line", canSave: true, save: save) {
            Section {
                Text(line.narration)
                LabeledContent("Date", value: PropertyLedger.day(line.date))
                LabeledContent("Amount", value: IndiaMoney.format(line.amount))
                if line.isManual {
                    LabeledContent("What", value: line.kind.title)
                } else {
                    Picker("What", selection: $kind) {
                        Text("Automatic (\(IndiaEntry.guess(narration: line.narration, amount: line.amount).title))").tag(IndiaEntry.Kind?.none)
                        ForEach(IndiaEntry.Kind.allCases, id: \.self) { Text($0.title).tag(IndiaEntry.Kind?.some($0)) }
                    }
                }
            }
            TaxRemoveButton(title: "Remove Line", warning: line.isManual ? "This can't be undone here." : "Importing the statement again brings it back.") {
                india.change { book in book.entries.removeAll { $0.id == line.id } }
            }
        }
    }

    private func save() {
        guard !line.isManual else { return }
        india.change { book in
            // Only a line still there is changed, so one removed meanwhile stays removed.
            guard var current = book.entries.first(where: { $0.id == line.id }) else { return }
            current.chosenKind = kind
            book.save(current)
        }
    }
}

private struct IndiaManualEditor: View {
    @EnvironmentObject var india: IndiaStore
    let accountID: String
    @State private var kind = IndiaEntry.Kind.interest
    @State private var amount = ""
    @State private var date = Date()
    @State private var note = ""

    var body: some View {
        TaxSheet(title: "Interest or Tax", canSave: (IndiaMoney.parse(amount) ?? 0) > 0, save: save) {
            Section {
                Picker("What", selection: $kind) {
                    ForEach([IndiaEntry.Kind.interest, .taxDeducted], id: \.self) { Text($0.title).tag($0) }
                }
                IndiaAmountField(title: "Amount (₹)", text: $amount)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Note (optional)", text: $note)
            } footer: {
                Text("For amounts no statement shows, such as deposit interest from the bank's certificate. Don't type in what a statement already has.")
            }
        }
    }

    private func save() {
        guard let rupees = IndiaMoney.parse(amount) else { return }
        india.change { $0.save(.manual(accountID: accountID, date: date, kind: kind, rupees: rupees, note: note.trimmingCharacters(in: .whitespacesAndNewlines))) }
    }
}
