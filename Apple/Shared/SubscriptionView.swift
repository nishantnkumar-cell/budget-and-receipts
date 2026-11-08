import BudgetCore
import SwiftUI

extension CommitmentKind {
    var title: String { self == .subscription ? "Subscription" : "Contract" }
    var symbol: String { self == .subscription ? "arrow.triangle.2.circlepath" : "doc.text" }
}

/// Plan: subscriptions (month to month) and fixed-term contracts, with the next 30 days at the top.
struct PlanView: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    @EnvironmentObject var store: BudgetStore
    @State private var deleting: SubscriptionContract?

    private var annualCost: Decimal {
        subscriptions.contracts
            .filter { $0.status == .active }
            .reduce(0) { $0 + SubscriptionSchedule().annualisedCost($1) }
    }

    private func items(_ kind: CommitmentKind) -> [SubscriptionContract] {
        subscriptions.contracts
            .filter { $0.resolvedKind == kind }
            .sorted { ($0.status == .active ? 0 : 1, $0.vendor.localizedLowercase) < ($1.status == .active ? 0 : 1, $1.vendor.localizedLowercase) }
    }

    var body: some View {
        let due = SubscriptionTracker().dueSoon(subscriptions.contracts, from: Date(), days: 30)
        let rises = subscriptions.priceRises(transactions: store.transactions)
        List {
            Section {
                LabeledContent("Committed per year") { Text(annualCost.money).fontWeight(.semibold).monospacedDigit() }
                LabeledContent("Due in the next 30 days") { Text("\(due.count)").fontWeight(.semibold) }
            }
            if !due.isEmpty {
                Section("Coming up") {
                    ForEach(due) { item in
                        NavigationLink { CommitmentEditor(item: item, priceRise: rises[item.id]) } label: { CommitmentRow(item: item, priceRise: rises[item.id]) }
                    }
                }
            }
            SetAsidesSection()
            list(.subscription, rises: rises)
            list(.contract, rises: rises)
            spottedSection
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationTitle("Plan")
        .alert("Delete \(deleting?.vendor ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { subscriptions.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("It stops showing in Coming up and reminders. Your payments stay.")
        }
    }

    private func list(_ kind: CommitmentKind, rises: [UUID: PriceRise]) -> some View {
        Section {
            ForEach(items(kind)) { item in
                DeletableRow(onDelete: { deleting = item }) {
                    NavigationLink { CommitmentEditor(item: item, priceRise: rises[item.id]) } label: { CommitmentRow(item: item, priceRise: rises[item.id]) }
                }
            }
            NavigationLink { CommitmentEditor(item: .blank(kind)) } label: {
                Label(kind == .subscription ? "Add Subscription" : "Add Contract", systemImage: "plus")
            }
        } header: {
            Label(kind == .subscription ? "Subscriptions" : "Contracts", systemImage: kind.symbol)
        } footer: {
            Text(kind == .subscription
                 ? "Month-to-month payments you can stop any time, like streaming, apps or the gym."
                 : "Deals with a fixed term, like a mobile phone or a fixed energy tariff. Their end dates show on Home under Renewals and contract dates.")
        }
    }

    @ViewBuilder private var spottedSection: some View {
        let spotted = store.spottedBills(besides: subscriptions.contracts)
        if !spotted.isEmpty {
            Section {
                ForEach(spotted) { payment in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(payment.name).font(.body.weight(.semibold))
                            Text("\(payment.period == .custom ? "Every \(payment.intervalDays ?? 0) days" : payment.period.title) · \(payment.count) payments so far")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(payment.amount.money).monospacedDigit()
                        Menu {
                            Button { add(payment, as: .subscription) } label: { Label("As a Subscription", systemImage: CommitmentKind.subscription.symbol) }
                            Button { add(payment, as: .contract) } label: { Label("As a Contract", systemImage: CommitmentKind.contract.symbol) }
                        } label: {
                            Text("Add")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .accessibilityLabel("Add \(payment.name)")
                    }
                }
            } header: {
                Text("Spotted on your statements")
            } footer: {
                Text("These already show in Coming up. Add one to keep track of it, and for a contract, when it ends.")
            }
        }
    }

    private func add(_ payment: RecurringPayment, as kind: CommitmentKind) {
        var item = payment.contract(currency: AppSettings.currency)
        item.kind = kind
        if kind == .contract { item.minimumTermEndDate = Calendar.current.date(byAdding: .month, value: 12, to: Date()) }
        subscriptions.save(item)
    }
}

struct CommitmentRow: View {
    let item: SubscriptionContract
    var priceRise: PriceRise?

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: item.resolvedKind.symbol, tint: item.status == .active ? .brandPlum : .secondary, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.vendor).font(.body.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.expectedAmount, format: .currency(code: item.currency))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if let priceRise { PriceRiseChip(rise: priceRise, currency: item.currency) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        guard item.status == .active else { return item.status.title }
        if item.isContract, let end = item.termEndDate {
            let left = item.monthsLeft(from: Date()) ?? 0
            if end < Date() { return "Term ended \(end.formatted(.dateTime.day().month(.abbreviated).year()))" }
            let remaining = left == 0 ? "under a month left" : left == 1 ? "1 month left" : "\(left) months left"
            return "Ends \(end.formatted(.dateTime.day().month(.abbreviated).year())) · \(remaining)"
        }
        return "\(item.billingPeriod.title) · next \(item.nextPaymentDueDate.formatted(.dateTime.day().month(.abbreviated)))"
    }
}

/// Adds or edits a subscription or a contract, and deletes it.
struct CommitmentEditor: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State var item: SubscriptionContract
    var priceRise: PriceRise?

    private var isNew: Bool { !subscriptions.contracts.contains { $0.id == item.id } }
    private var kind: CommitmentKind { item.resolvedKind }

    var body: some View {
        Form {
            if let priceRise {
                Section {
                    Label("Went up from \(priceRise.previous.formatted(.currency(code: item.currency))) to \(priceRise.latest.formatted(.currency(code: item.currency))) on \(priceRise.date.formatted(.dateTime.day().month(.abbreviated))), \(priceRise.percent.formatted(.percent.precision(.fractionLength(0)))) more.",
                          systemImage: "arrow.up.circle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                TextField(kind == .subscription ? "Name" : "Provider", text: $item.vendor, prompt: Text(kind == .subscription ? "e.g. Netflix" : "e.g. Vodafone"))
                Picker("Type", selection: $item.category) {
                    ForEach(SubscriptionCategory.allCases) { Text($0.title).tag($0) }
                }
                Picker("This is a", selection: Binding(get: { kind }, set: { setKind($0) })) {
                    ForEach(CommitmentKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            }
            Section("Payments") {
                TextField(kind == .subscription ? "Price" : "Cost", value: $item.expectedAmount, format: .number).decimalKeyboard()
                Picker("Paid", selection: $item.billingPeriod) {
                    ForEach(BillingPeriod.allCases.filter { $0 != .custom || item.billingPeriod == .custom }) { Text($0.title).tag($0) }
                }
                DatePicker("Next payment", selection: $item.nextPaymentDueDate, displayedComponents: .date)
                ReminderPicker(daysBefore: $item.remindDaysBefore)
            }
            if kind == .contract { termSection }
            Section {
                Picker("Status", selection: $item.status) {
                    ForEach(statuses) { Text($0.title).tag($0) }
                }
                TextField("Notes", text: $item.notes, axis: .vertical)
                PrivateToggle(isPrivate: $item.isPrivate)
            }
            if !isNew {
                DeleteSection(title: kind == .subscription ? "Delete Subscription" : "Delete Contract",
                              message: "It stops showing in Coming up and reminders. Your payments stay.") {
                    subscriptions.delete(item)
                    dismiss()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? (kind == .subscription ? "New subscription" : "New contract") : item.vendor)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    item.vendor = item.vendor.trimmingCharacters(in: .whitespaces)
                    item.kind = kind
                    subscriptions.save(item)
                    dismiss()
                }
                .disabled(item.vendor.trimmingCharacters(in: .whitespaces).isEmpty || item.expectedAmount < 0)
            }
        }
    }

    private var statuses: [SubscriptionStatus] {
        kind == .subscription ? [.active, .paused, .cancelled] : [.active, .expired, .cancelled]
    }

    @ViewBuilder private var termSection: some View {
        Section {
            DatePicker("Started", selection: $item.startDate, displayedComponents: .date)
            Picker("Length", selection: termLength) {
                ForEach(Self.lengths, id: \.self) { Text("\($0) months").tag($0) }
                Text("Other").tag(0)
            }
            DatePicker("Ends", selection: Binding(get: { item.minimumTermEndDate ?? Self.end(of: item.startDate, months: 24) }, set: { item.minimumTermEndDate = $0 }),
                       displayedComponents: .date)
            Toggle("Fixed price", isOn: Binding(get: { item.pricing == .fixed }, set: { item.pricing = $0 ? .fixed : .variable }))
            if item.pricing == .fixed {
                OptionalDatePicker(title: "Price fixed until", date: $item.fixedPriceEndDate)
            }
        } header: {
            Text("Term")
        } footer: {
            if let left = item.monthsLeft(from: Date()), left > 0 {
                Text("\(left) month\(left == 1 ? "" : "s") to go.")
            }
        }
        Section {
            Picker("Notice to cancel", selection: Binding(get: { item.cancellationNoticeDays ?? 0 }, set: { item.cancellationNoticeDays = $0 == 0 ? nil : $0 })) {
                Text("None").tag(0)
                ForEach([14, 30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                if let days = item.cancellationNoticeDays, ![0, 14, 30, 60, 90].contains(days) { Text("\(days) days").tag(days) }
            }
            OptionalDatePicker(title: "Renews by itself on", date: $item.renewalDate)
        } header: {
            Text("When it ends")
        } footer: {
            Text("Home shows the end date, the last day to give notice and any renewal, up to 90 days ahead.")
        }
    }

    static let lengths = [12, 18, 24, 36]

    static func end(of start: Date, months: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: months, to: start) ?? start
    }

    /// The term in months when the end date is a whole number of months after the start.
    private var termLength: Binding<Int> {
        Binding(
            get: {
                guard let end = item.minimumTermEndDate else { return 0 }
                return Self.lengths.first { Calendar.current.isDate(Self.end(of: item.startDate, months: $0), inSameDayAs: end) } ?? 0
            },
            set: { months in if months > 0 { item.minimumTermEndDate = Self.end(of: item.startDate, months: months) } }
        )
    }

    private func setKind(_ newKind: CommitmentKind) {
        item.kind = newKind
        if newKind == .contract, item.minimumTermEndDate == nil {
            item.minimumTermEndDate = Self.end(of: item.startDate, months: 24)
        }
        if !statuses.contains(item.status) { item.status = .active }
    }
}

extension SubscriptionContract {
    static func blank(_ kind: CommitmentKind = .subscription) -> SubscriptionContract {
        var item = SubscriptionContract(vendor: "", category: kind == .contract ? .mobile : .streaming, startDate: Date(), billingPeriod: .monthly,
                                        nextPaymentDueDate: Date(), expectedAmount: 0, currency: AppSettings.currency, kind: kind)
        if kind == .contract {
            item.minimumTermEndDate = CommitmentEditor.end(of: Date(), months: 24)
            item.pricing = .fixed
        }
        return item
    }
}

struct OptionalDatePicker: View {
    let title: String
    @Binding var date: Date?
    var body: some View { HStack { Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? Date() : nil })); if let value = date { DatePicker("", selection: Binding(get: { value }, set: { date = $0 }), displayedComponents: .date).labelsHidden() } } }
}
