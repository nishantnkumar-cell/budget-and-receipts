import BudgetCore
import SwiftUI

extension View {
    /// Decimal keypad on iPhone; no-op on Mac.
    func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    /// Small inline navigation title on iPhone; no-op on Mac.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Activity: every transaction, newest first, grouped by day and searchable.
struct TransactionsView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var query = ""
    @State private var addingTransaction = false

    private var shown: [BankTransaction] {
        let all = store.transactions
            .filter { store.accountFilter == nil || $0.accountID == store.accountFilter }
            .filter { !store.hasPartner || store.householdView.includes(store.ledger.owner(of: $0)) }
            .sorted { $0.date > $1.date }
        guard !query.isEmpty else { return all }
        return all.filter { $0.matches(query) }
    }

    private var days: [(day: Date, transactions: [BankTransaction])] {
        Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, transactions: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        List {
            ForEach(days, id: \.day) { group in
                Section(group.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(group.transactions) { transaction in
                        NavigationLink {
                            TransactionEditor(transaction: transaction)
                        } label: {
                            TransactionRow(transaction: transaction)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.delete(transaction)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) { store.delete(transaction) }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .overlay {
            if store.transactions.isEmpty {
                ContentUnavailableView("No transactions yet", systemImage: "list.bullet.rectangle", description: Text("Import a bank statement or add a transaction."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .top) {
            if store.hasPartner {
                HouseholdSwitcher().padding(.horizontal).padding(.vertical, 8)
            }
        }
        .safeAreaInset(edge: .bottom) { CategorisingBanner().padding(.bottom, 8) }
        .searchable(text: $query)
        .sheet(isPresented: $addingTransaction) {
            NavigationStack { NewTransactionView() }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { AccountFilterMenu() }
            ToolbarItem(placement: .primaryAction) {
                Button { addingTransaction = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add transaction")
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { ImportStatementView() } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel("Import statement")
            }
        }
    }
}

extension BankTransaction {
    /// Search used everywhere (Activity, the Mac Overview and ⌘K): shop, category or
    /// sub-category, tag, or an amount such as "12.50" or "£12.50".
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if merchant.localizedCaseInsensitiveContains(query)
            || FinanceCategories.label(category, subcategory).localizedCaseInsensitiveContains(query)
            || (tags ?? []).contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
            return true
        }
        // Only a query with no letters is an amount, so "Tesco 2" doesn't match every £2.
        guard !query.contains(where: \.isLetter) else { return false }
        let digits = query.filter { $0.isNumber || $0 == "." }
        guard !digits.isEmpty, let amount = Decimal(string: digits) else { return false }
        return abs(self.amount) == amount
    }
}

struct TransactionEditor: View {
    @EnvironmentObject var store: BudgetStore
    @State var transaction: BankTransaction
    @State private var savedCategory: String?
    @State private var similarCount = 0

    var body: some View {
        Form {
            DatePicker("Date", selection: $transaction.date, displayedComponents: .date)
            TextField("Merchant", text: $transaction.merchant)
            TextField("Description", text: $transaction.description)
            SignedAmountField(amount: $transaction.amount)
            CategoryPickers(category: $transaction.category, subcategory: $transaction.subcategory)
            if !store.accounts.isEmpty {
                AccountPicker(selection: $transaction.accountID)
            }
            PrivateToggle(isPrivate: $transaction.isPrivate)
            TransactionOwnerSection(transaction: $transaction)
            Section("Receipt") {
                NavigationLink("Scan or review receipt") { ReceiptView(transaction: transaction) }
            }
            Section { MakeRuleButton(transaction: transaction) }
            TransactionTagsSection(tags: Binding(get: { transaction.tags ?? [] }, set: { transaction.tags = $0.isEmpty ? nil : $0 }))
            TransactionNotesSection(transaction: transaction)
            Section {
                DeleteTransactionButton(transaction: transaction)
            }
        }
        .navigationTitle("Edit")
        .onAppear { if savedCategory == nil { savedCategory = transaction.category } }
        .toolbar {
            Button("Save", action: save)
        }
        // One correction teaches the rest: offer the same category for this shop's other payments.
        .alert("Apply \(transaction.category) to \(similarCount) more from \(transaction.merchant)?", isPresented: Binding(get: { similarCount > 0 }, set: { if !$0 { similarCount = 0 } })) {
            Button("Apply to All") { store.applyCategory(transaction.category, toSimilar: transaction) }
            Button("Just This One", role: .cancel) {}
        } message: {
            Text("They're still uncategorised.")
        }
    }

    private func save() {
        // A category you pick yourself is kept, even if it looks like a transfer.
        if transaction.category != savedCategory { transaction.categoryChosen = true }
        store.update(transaction)
        if transaction.category != savedCategory, transaction.category != "Uncategorised" {
            similarCount = store.similarUncategorised(to: transaction).count
        }
        savedCategory = transaction.category
    }
}
