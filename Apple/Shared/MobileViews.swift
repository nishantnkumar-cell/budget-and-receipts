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
        return all.filter {
            $0.merchant.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
        }
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

struct TransactionEditor: View {
    @EnvironmentObject var store: BudgetStore
    @State var transaction: BankTransaction

    var body: some View {
        Form {
            DatePicker("Date", selection: $transaction.date, displayedComponents: .date)
            TextField("Merchant", text: $transaction.merchant)
            TextField("Description", text: $transaction.description)
            SignedAmountField(amount: $transaction.amount)
            Picker("Category", selection: $transaction.category) {
                ForEach(FinanceCategories.all, id: \.self) { Text($0).tag($0) }
            }
            if !store.accounts.isEmpty {
                AccountPicker(selection: $transaction.accountID)
            }
            PrivateToggle(isPrivate: $transaction.isPrivate)
            TransactionOwnerSection(transaction: $transaction)
            Section("Receipt") {
                NavigationLink("Scan or review receipt") { ReceiptView(transaction: transaction) }
            }
            Section {
                DeleteTransactionButton(transaction: transaction)
            }
        }
        .navigationTitle("Edit")
        .toolbar {
            Button("Save") { store.update(transaction) }
        }
    }
}

/// Plan: bills, subscriptions and contracts, with the next 30 days at the top.
struct PlanView: View {
    @EnvironmentObject var subscriptions: SubscriptionStore

    private var annualCost: Decimal {
        subscriptions.contracts
            .filter { $0.status == .active }
            .reduce(0) { $0 + SubscriptionSchedule().annualisedCost($1) }
    }

    var body: some View {
        let due = SubscriptionTracker().dueSoon(subscriptions.contracts, from: Date(), days: 30)
        List {
            Section {
                LabeledContent("Committed per year") { Text(annualCost.money).fontWeight(.semibold).monospacedDigit() }
                LabeledContent("Due in the next 30 days") { Text("\(due.count)").fontWeight(.semibold) }
            }
            if !due.isEmpty {
                Section("Coming up") {
                    ForEach(due) { contract in
                        NavigationLink { ContractEditor(contract: contract) } label: { ContractRow(contract: contract) }
                    }
                }
            }
            Section("All bills and subscriptions") {
                ForEach(subscriptions.contracts) { contract in
                    NavigationLink { ContractEditor(contract: contract) } label: { ContractRow(contract: contract) }
                }
                NavigationLink { ContractEditor(contract: .blank()) } label: {
                    Label("Add a bill or subscription", systemImage: "plus")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationTitle("Plan")
    }
}

struct ContractRow: View {
    let contract: SubscriptionContract

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(contract.vendor).font(.body.weight(.semibold))
                Text("Next \(contract.nextPaymentDueDate.formatted(.dateTime.day().month(.abbreviated))) · \(contract.billingPeriod.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(contract.expectedAmount, format: .currency(code: contract.currency))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct ContractEditor: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Environment(\.dismiss) var dismiss
    @State var contract: SubscriptionContract

    var body: some View {
        Form {
            TextField("Vendor", text: $contract.vendor)
            Picker("Type", selection: $contract.category) {
                ForEach(SubscriptionCategory.allCases) { Text($0.title).tag($0) }
            }
            DatePicker("Start date", selection: $contract.startDate, displayedComponents: .date)
            DatePicker("Next payment", selection: $contract.nextPaymentDueDate, displayedComponents: .date)
            TextField("Amount", value: $contract.expectedAmount, format: .number).decimalKeyboard()
            Picker("Period", selection: $contract.billingPeriod) {
                ForEach(BillingPeriod.allCases) { Text($0.title).tag($0) }
            }
            Picker("Pricing", selection: $contract.pricing) {
                ForEach(ContractPricing.allCases) { Text($0.title).tag($0) }
            }
        }
        .navigationTitle("Contract")
        .toolbar {
            Button("Save") {
                subscriptions.save(contract)
                dismiss()
            }
            .disabled(contract.vendor.isEmpty)
        }
    }
}

extension SubscriptionContract {
    static func blank() -> SubscriptionContract {
        SubscriptionContract(vendor: "", category: .other, startDate: Date(), billingPeriod: .monthly, nextPaymentDueDate: Date(), expectedAmount: 0, currency: AppSettings.currency)
    }
}
