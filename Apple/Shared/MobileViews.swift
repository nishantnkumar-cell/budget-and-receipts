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

struct MoneyCard: View {
    let title: String
    let amount: Decimal
    let colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(amount, format: .currency(code: AppSettings.currency))
                .font(.title2.bold())
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct OverviewView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore

    private var annualContracts: Decimal {
        subscriptions.contracts
            .filter { $0.status == .active }
            .reduce(0) { $0 + SubscriptionSchedule().annualisedCost($1) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text("Personal Budget").font(.largeTitle.bold())
                    Spacer()
                    MonthSwitcher()
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                    MoneyCard(title: "Income", amount: store.income, colour: .green)
                    MoneyCard(title: "Spending", amount: store.spending, colour: .brandPink)
                    MoneyCard(title: "Net", amount: store.income - store.spending, colour: .brandIndigo)
                    MoneyCard(title: "Annual contracts", amount: annualContracts, colour: .brandAmber)
                }
                NavigationLink {
                    ReviewView()
                } label: {
                    Label("\(store.needsReview.count) items need review", systemImage: "checklist")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.brandAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                }
                UpcomingContractsView()
            }
            .padding()
        }
        .navigationTitle("Overview")
        .inlineNavigationTitle()
    }
}

struct TransactionsView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var query = ""

    private var shown: [BankTransaction] {
        guard !query.isEmpty else { return store.transactions }
        return store.transactions.filter {
            $0.merchant.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            ForEach(shown) { transaction in
                NavigationLink {
                    TransactionEditor(transaction: transaction)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(transaction.merchant).font(.headline)
                            Text(transaction.category).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(transaction.amount, format: .currency(code: AppSettings.currency))
                            .foregroundStyle(transaction.amount < 0 ? .primary : Color.green)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.delete(transaction)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Transactions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: store.addTransaction) { Image(systemName: "plus") }
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
            TextField("Amount", value: $transaction.amount, format: .number).decimalKeyboard()
            Picker("Category", selection: $transaction.category) {
                ForEach(FinanceCategories.all, id: \.self) { Text($0).tag($0) }
            }
            Section("Receipt") {
                NavigationLink("Scan or review receipt") { ReceiptView(transaction: transaction) }
            }
        }
        .navigationTitle("Edit")
        .toolbar {
            Button("Save") { store.update(transaction) }
        }
    }
}

struct RecurringView: View {
    @EnvironmentObject var subscriptions: SubscriptionStore

    var body: some View {
        List {
            NavigationLink("Add contract") { ContractEditor(contract: .blank()) }
            ForEach(subscriptions.contracts) { contract in
                NavigationLink {
                    ContractEditor(contract: contract)
                } label: {
                    VStack(alignment: .leading) {
                        Text(contract.vendor).font(.headline)
                        Text("Next: \(contract.nextPaymentDueDate.formatted(date: .abbreviated, time: .omitted)) · \(contract.expectedAmount.formatted(.currency(code: contract.currency)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Recurring")
    }
}

struct ReviewView: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        List(store.needsReview) { transaction in
            NavigationLink {
                TransactionEditor(transaction: transaction)
            } label: {
                VStack(alignment: .leading) {
                    Text(transaction.merchant).bold()
                    Text(transaction.pendingSplitDraft == nil ? "Uncategorised" : "Receipt split awaiting approval")
                        .font(.caption)
                        .foregroundStyle(.brandAmber)
                }
            }
        }
        .navigationTitle("Review")
    }
}

struct UpcomingContractsView: View {
    @EnvironmentObject var subscriptions: SubscriptionStore

    var body: some View {
        VStack(alignment: .leading) {
            Text("Upcoming payments").font(.headline)
            ForEach(SubscriptionTracker().dueSoon(subscriptions.contracts, from: Date(), days: 30).prefix(5)) { contract in
                HStack {
                    Text(contract.vendor)
                    Spacer()
                    Text(contract.expectedAmount, format: .currency(code: contract.currency))
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
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
