import BudgetCore
import SwiftUI

struct SubscriptionView: View {
    @ObservedObject var subscriptionStore: SubscriptionStore
    let transactions: [BankTransaction]
    @State private var editing: SubscriptionContract?
    private let tracker = SubscriptionTracker()

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Contracts & Subscriptions").font(.largeTitle.bold())
                Spacer()
                Button("Add Contract") { editing = newContract() }.buttonStyle(.borderedProminent)
            }.padding()
            HStack(spacing: 12) {
                GroupBox("Due in 30 days") { Text("\(tracker.dueSoon(subscriptionStore.contracts, from: Date()).count)").font(.title.bold()).frame(minWidth: 130) }
                GroupBox("Renewing in 60 days") { Text("\(tracker.renewalSoon(subscriptionStore.contracts, from: Date()).count)").font(.title.bold()).frame(minWidth: 150) }
                GroupBox("Annual committed cost") { Text(annualTotal, format: .currency(code: "GBP")).font(.title2.bold()).frame(minWidth: 180) }
            }.padding(.horizontal)
            Table(subscriptionStore.contracts) {
                TableColumn("Vendor", value: \.vendor)
                TableColumn("Type") { Text($0.category.title) }
                TableColumn("Next payment") { Text($0.nextPaymentDueDate, format: .dateTime.day().month().year()) }
                TableColumn("Amount") { Text($0.expectedAmount, format: .currency(code: $0.currency)) }
                TableColumn("Renewal") { contract in if let renewal = contract.renewalDate { Text(renewal, format: .dateTime.day().month().year()) } else { Text("Not set").foregroundStyle(.secondary) } }
                TableColumn("Paid to vendor") { contract in Text(tracker.vendorSummary(contract: contract, transactions: transactions).totalPaid, format: .currency(code: contract.currency)) }
                TableColumn("Edit") { contract in Button("Edit") { editing = contract }.buttonStyle(.borderless) }
            }.padding()
        }.sheet(item: $editing) { contract in SubscriptionEditor(contract: contract) { subscriptionStore.save($0) }.frame(width: 700, height: 620) }
    }

    var annualTotal: Decimal { subscriptionStore.contracts.filter { $0.status == .active }.reduce(0) { $0 + SubscriptionSchedule().annualisedCost($1) } }
    func newContract() -> SubscriptionContract { SubscriptionContract(vendor: "", category: .other, startDate: Date(), billingPeriod: .monthly, nextPaymentDueDate: Date(), expectedAmount: 0) }
}

struct SubscriptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var contract: SubscriptionContract
    let onSave: (SubscriptionContract) -> Void

    var body: some View {
        Form {
            Section("Contract") {
                TextField("Vendor", text: $contract.vendor)
                Picker("Type", selection: $contract.category) { ForEach(SubscriptionCategory.allCases) { Text($0.title).tag($0) } }
                DatePicker("Start date", selection: $contract.startDate, displayedComponents: .date)
                OptionalDatePicker(title: "Minimum term ends", date: $contract.minimumTermEndDate)
                OptionalDatePicker(title: "Renewal date", date: $contract.renewalDate)
                Picker("Status", selection: $contract.status) { ForEach(SubscriptionStatus.allCases) { Text($0.rawValue.capitalized).tag($0) } }
            }
            Section("Payments") {
                Picker("Billing period", selection: $contract.billingPeriod) { ForEach(BillingPeriod.allCases) { Text($0.title).tag($0) } }
                if contract.billingPeriod == .custom { TextField("Custom interval days", value: $contract.customIntervalDays, format: .number) }
                DatePicker("Next payment due", selection: $contract.nextPaymentDueDate, displayedComponents: .date)
                TextField("Expected amount", value: $contract.expectedAmount, format: .number)
                Picker("Pricing", selection: $contract.pricing) { ForEach(ContractPricing.allCases) { Text($0.title).tag($0) } }
                if contract.pricing == .fixed || contract.pricing == .introductory { OptionalDatePicker(title: "Price fixed until", date: $contract.fixedPriceEndDate) }
            }
            Section("Renewal & matching") {
                TextField("Cancellation notice days", value: $contract.cancellationNoticeDays, format: .number)
                TextField("Account reference", text: $contract.accountReference)
                TextField("Statement match terms, comma separated", text: Binding(get: { contract.transactionMatchers.joined(separator: ", ") }, set: { contract.transactionMatchers = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                TextField("Notes", text: $contract.notes, axis: .vertical)
            }
        }.formStyle(.grouped).toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(contract); dismiss() }.disabled(contract.vendor.isEmpty || contract.expectedAmount < 0).keyboardShortcut(.defaultAction) }
        }
    }
}

struct OptionalDatePicker: View {
    let title: String
    @Binding var date: Date?
    var body: some View { HStack { Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? Date() : nil })); if let value = date { DatePicker("", selection: Binding(get: { value }, set: { date = $0 }), displayedComponents: .date).labelsHidden() } } }
}
