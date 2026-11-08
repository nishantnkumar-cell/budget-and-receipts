import BudgetCore
import SwiftUI

// Savings goals, money being paid back to you, and trips (with exchange rates and card fees).
// They live in Plan; a payment's own editor has the reimbursement, trip and currency details.

// MARK: - Savings goals

/// Plan's goals: a progress row for each, and Add Goal.
struct SavingsGoalsSection: View {
    @EnvironmentObject var store: BudgetStore
    @State private var deleting: SavingsGoal?

    var body: some View {
        Section {
            ForEach(store.viewGoals.sorted { ($0.isReached ? 1 : 0, $0.deadline ?? .distantFuture) < ($1.isReached ? 1 : 0, $1.deadline ?? .distantFuture) }) { goal in
                DeletableRow(onDelete: { deleting = goal }) {
                    NavigationLink { SavingsGoalEditor(goal: goal) } label: { SavingsGoalRow(goal: goal) }
                }
            }
            NavigationLink { SavingsGoalEditor(goal: SavingsGoal(name: "", target: 0, owner: store.hasPartner ? .shared : nil)) } label: {
                Label("Add Goal", systemImage: "plus")
            }
        } header: {
            Label("Savings goals", systemImage: "star")
        } footer: {
            Text(store.hasPartner
                 ? "Save on your own or together. Add money as you put it aside; each of you can add to a shared goal."
                 : "Something you're saving up for. Add money as you put it aside to see how close you are.")
        }
        .alert("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { store.deleteGoal(deleting) }
                deleting = nil
            }
        } message: {
            Text("The goal and what you've recorded against it go. Your money and payments don't change.")
        }
    }
}

struct SavingsGoalRow: View {
    @EnvironmentObject var store: BudgetStore
    let goal: SavingsGoal

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: goal.symbol ?? "star", tint: goal.isReached ? .green : .brandPink)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(goal.name).font(.body.weight(.semibold)).lineLimit(1)
                    if store.hasPartner, let owner = goal.owner, owner != .shared { OwnerChip(owner: owner, partnerName: store.couple.partnerName) }
                    Spacer()
                    Text("\(goal.saved.wholeMoney) of \(goal.target.wholeMoney)").font(.subheadline).monospacedDigit()
                }
                ProgressView(value: goal.progress).tint(goal.isReached ? .green : .brandPink)
                Text(detail).font(.caption).foregroundStyle(goal.isBehind() ? Color.brandAmber : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        if goal.isReached { return "Reached" }
        var parts: [String] = []
        if let monthly = goal.monthlyNeeded(), let deadline = goal.deadline {
            parts.append("\(monthly.money) a month to reach it by \(deadline.formatted(.dateTime.month(.abbreviated).year()))")
        } else {
            parts.append("\(goal.remaining.money) to go")
        }
        if goal.isBehind() { parts.append("behind") }
        return parts.joined(separator: " · ")
    }
}

/// Add or change a goal, and record money put in or taken out.
struct SavingsGoalEditor: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State var goal: SavingsGoal
    @State private var adding: Decimal?
    @State private var addingBy: Person = .me
    @State private var editingContribution: SavingsGoal.Contribution?

    private var isNew: Bool { !store.goals.contains { $0.id == goal.id } }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $goal.name, prompt: Text("e.g. Japan trip"))
                TextField("Target", value: $goal.target, format: .number).decimalKeyboard()
                OptionalDatePicker(title: "Reach it by", date: $goal.deadline)
                Picker("Symbol", selection: Binding(get: { goal.symbol ?? "star" }, set: { goal.symbol = $0 })) {
                    ForEach(SavingsGoal.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                }
                if store.hasPartner {
                    Picker("Whose", selection: Binding(get: { goal.owner ?? .shared }, set: { goal.owner = $0 })) {
                        ForEach(MoneyOwner.allCases, id: \.self) { Text($0.label(partnerName: store.couple.partnerName)).tag($0) }
                    }
                }
                PrivateToggle(isPrivate: $goal.isPrivate)
            } footer: {
                if let monthly = goal.monthlyNeeded() {
                    Text("Put aside \(monthly.money) a month to get there in time.")
                } else if let projected = goal.projectedDate() {
                    Text("At your recent pace you'll get there around \(projected.formatted(.dateTime.month(.wide).year())).")
                }
            }
            Section {
                HStack {
                    TextField("Amount", value: $adding, format: .number).decimalKeyboard()
                    if store.hasPartner, (goal.owner ?? .shared) == .shared {
                        Picker("By", selection: $addingBy) {
                            Text("Me").tag(Person.me)
                            Text(store.couple.partnerName).tag(Person.partner)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Button("Add") {
                        guard let adding, adding != 0 else { return }
                        goal.contributions.append(.init(amount: adding, by: addingBy == .me ? nil : .partner))
                        self.adding = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled((adding ?? 0) == 0)
                }
                ForEach(goal.contributions.sorted { $0.date > $1.date }) { contribution in
                    DeletableRow(label: "Delete Amount", onDelete: { goal.contributions.removeAll { $0.id == contribution.id } }) {
                        Button { editingContribution = contribution } label: {
                            LabeledContent {
                                Text(contribution.amount.money).monospacedDigit().foregroundStyle(contribution.amount < 0 ? Color.brandPink : .primary)
                            } label: {
                                Text(contribution.date.formatted(date: .abbreviated, time: .omitted))
                                if store.hasPartner { Text(contribution.by == .partner ? store.couple.partnerName : "Me") }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Saved \(goal.saved.money)")
            } footer: {
                Text("Enter a negative amount for money taken back out. Tap an amount to change it.")
            }
            if !isNew {
                DeleteSection(title: "Delete Goal", message: "What you've recorded against it goes too.") {
                    store.deleteGoal(goal)
                    dismiss()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New goal" : goal.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    goal.name = goal.name.trimmingCharacters(in: .whitespaces)
                    store.saveGoal(goal)
                    dismiss()
                }
                .disabled(goal.name.trimmingCharacters(in: .whitespaces).isEmpty || goal.target <= 0)
            }
        }
        .sheet(item: $editingContribution) { contribution in
            NavigationStack {
                ContributionEditor(contribution: contribution, partnerName: store.hasPartner ? store.couple.partnerName : nil) { changed in
                    if let index = goal.contributions.firstIndex(where: { $0.id == changed.id }) { goal.contributions[index] = changed }
                } onDelete: {
                    goal.contributions.removeAll { $0.id == contribution.id }
                }
            }
        }
    }
}

struct ContributionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var contribution: SavingsGoal.Contribution
    let partnerName: String?
    let onSave: (SavingsGoal.Contribution) -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            DatePicker("Date", selection: $contribution.date, displayedComponents: .date)
            TextField("Amount", value: $contribution.amount, format: .number).decimalKeyboard()
            if let partnerName {
                Picker("By", selection: Binding(get: { contribution.by ?? .me }, set: { contribution.by = $0 == .me ? nil : $0 })) {
                    Text("Me").tag(Person.me)
                    Text(partnerName).tag(Person.partner)
                }
            }
            TextField("Note", text: Binding(get: { contribution.note ?? "" }, set: { contribution.note = $0.isEmpty ? nil : $0 }))
            DeleteSection(title: "Delete Amount", message: "It comes off the goal's total.") {
                onDelete()
                dismiss()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Amount")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onSave(contribution); dismiss() }
            }
        }
    }
}

/// Home's goals, when there are any and Settings shows them.
struct GoalsPanel: View {
    @EnvironmentObject var store: BudgetStore
    @AppStorage("showGoalsOnHome") private var showGoals = true

    var body: some View {
        let goals = store.viewGoals.filter { !$0.isReached }.prefix(3)
        if showGoals, !goals.isEmpty {
            OverviewPanel(title: "Savings goals", symbol: "star") {
                ForEach(Array(goals)) { goal in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(goal.name).lineLimit(1)
                            Spacer()
                            Text("\(goal.saved.wholeMoney) of \(goal.target.wholeMoney)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ProgressView(value: goal.progress).tint(.brandPink)
                    }
                }
            }
        }
    }
}

// MARK: - Reimbursements

/// Plan's list of money still owed back to you.
struct OwedBackSection: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        let owed = store.outstandingReimbursements
        if !owed.isEmpty {
            Section {
                ForEach(owed) { item in
                    NavigationLink { TransactionEditor(transaction: item.transaction) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.transaction.merchant).lineLimit(1)
                                Text("\(item.from) · \(item.transaction.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.amount.money).monospacedDigit()
                        }
                    }
                }
            } header: {
                Label("Owed back to you", systemImage: "arrow.uturn.backward.circle")
            } footer: {
                let total = owed.reduce(Decimal(0)) { $0 + $1.amount }
                Text("\(total.money) still to come back. These payments don't count as your spending.")
            }
        }
    }
}

/// In a payment's editor: someone is paying it back.
struct ReimbursementSection: View {
    @EnvironmentObject var store: BudgetStore
    @Binding var transaction: BankTransaction

    var body: some View {
        if transaction.amount < 0 {
            Section {
                Toggle("Someone's paying this back", isOn: Binding(
                    get: { transaction.reimbursement != nil },
                    set: { on in transaction.reimbursement = on ? Reimbursement(from: Reimbursements.payers(store.transactions).first ?? "Work", amount: -transaction.amount) : nil }
                ))
                if transaction.reimbursement != nil {
                    HStack {
                        TextField("Who", text: Binding(get: { transaction.reimbursement?.from ?? "" }, set: { transaction.reimbursement?.from = $0 }), prompt: Text("e.g. Work"))
                        let payers = Reimbursements.payers(store.transactions)
                        if !payers.isEmpty {
                            Menu {
                                ForEach(payers, id: \.self) { name in Button(name) { transaction.reimbursement?.from = name } }
                            } label: { Image(systemName: "person.crop.circle") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("Choose who")
                        }
                    }
                    TextField("Amount paid back", value: Binding(get: { transaction.reimbursement?.amount ?? 0 }, set: { transaction.reimbursement?.amount = min(max($0, 0), -transaction.amount) }), format: .number)
                        .decimalKeyboard()
                    repaidRow
                }
            } header: {
                Text("Paid back")
            } footer: {
                if let reimbursement = transaction.reimbursement {
                    let kept = -transaction.amountAfterReimbursement
                    Text(kept > 0 ? "Only \(kept.money) counts as your spending." : "This payment doesn't count as your spending.")
                        + Text(reimbursement.isReceived ? "" : " Mark it paid back when the money arrives.")
                } else {
                    Text("For work expenses or a friend's share: what's paid back stops counting as your spending.")
                }
            }
        }
    }

    @ViewBuilder private var repaidRow: some View {
        if let reimbursement = transaction.reimbursement {
            if reimbursement.isReceived {
                LabeledContent("Paid back") {
                    HStack {
                        Text(reimbursement.receivedOn?.formatted(date: .abbreviated, time: .omitted) ?? "")
                        if let id = reimbursement.repaymentID, let credit = store.transactions.first(where: { $0.id == id }) {
                            Text("· \(credit.merchant)").lineLimit(1)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Button("Not Paid Back Yet") {
                    transaction.reimbursement?.receivedOn = nil
                    transaction.reimbursement?.repaymentID = nil
                }
            } else {
                let candidates = Reimbursements.candidates(for: transaction, in: store.transactions)
                Menu {
                    ForEach(candidates.prefix(5)) { credit in
                        Button("\(credit.merchant), \(credit.date.formatted(date: .abbreviated, time: .omitted))") {
                            transaction.reimbursement?.receivedOn = credit.date
                            transaction.reimbursement?.repaymentID = credit.id
                        }
                    }
                    if !candidates.isEmpty { Divider() }
                    Button("Paid Back Today, Not on a Statement") { transaction.reimbursement?.receivedOn = Date() }
                } label: {
                    Label(candidates.isEmpty ? "Mark Paid Back" : "Mark Paid Back (\(candidates.count) possible match\(candidates.count == 1 ? "" : "es"))", systemImage: "checkmark.circle")
                }
            }
        }
    }
}

// MARK: - Trips

/// Plan's trips: the latest few, with a link to all of them.
struct TripsSection: View {
    @EnvironmentObject var store: BudgetStore
    @State private var deleting: Trip?

    var body: some View {
        Section {
            ForEach(store.trips.prefix(4)) { trip in
                DeletableRow(onDelete: { deleting = trip }) {
                    NavigationLink { TripDetailView(tripID: trip.id) } label: { TripRow(trip: trip) }
                }
            }
            if store.trips.count > 4 {
                NavigationLink("All \(store.trips.count) Trips") { TripsListView() }
            }
            NavigationLink { TripEditor(trip: .blank) } label: { Label("Add Trip", systemImage: "plus") }
        } header: {
            Label("Trips", systemImage: "airplane")
        } footer: {
            Text("A holiday's total, with the exchange rate you got and card fees. Payments in another currency or card fees during the trip's dates join it by themselves.")
        }
        .alert("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { store.deleteTrip(deleting) }
                deleting = nil
            }
        } message: {
            Text("Its payments stay, just not on a trip.")
        }
    }
}

struct TripsListView: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        List {
            ForEach(store.trips) { trip in
                DeletableRow(onDelete: { store.deleteTrip(trip) }) {
                    NavigationLink { TripDetailView(tripID: trip.id) } label: { TripRow(trip: trip) }
                }
            }
        }
        .navigationTitle("Trips")
    }
}

extension Trip {
    static var blank: Trip {
        let start = Calendar.current.startOfDay(for: Date())
        return Trip(name: "", start: start, end: Calendar.current.date(byAdding: .day, value: 6, to: start) ?? start)
    }

    var dates: String { "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated).year()))" }
}

struct TripRow: View {
    @EnvironmentObject var store: BudgetStore
    let trip: Trip

    var body: some View {
        let summary = store.summary(of: trip)
        HStack(spacing: 12) {
            IconBadge(systemImage: "airplane", tint: .brandTeal)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(trip.dates + (summary.fees > 0 ? " · \(summary.fees.money) card fees" : "")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(summary.total.money).monospacedDigit().fontWeight(.semibold)
        }
    }
}

/// One trip: its total, rate, fees, categories and payments.
struct TripDetailView: View {
    @EnvironmentObject var store: BudgetStore
    let tripID: UUID
    @State private var editing = false

    var body: some View {
        if let trip = store.trips.first(where: { $0.id == tripID }) {
            let summary = store.summary(of: trip)
            let suggestions = TripLedger.suggestions(for: trip, in: store.transactions, calendar: store.calculator.calendar)
            List {
                Section {
                    LabeledContent("Total") { Text(summary.total.money).fontWeight(.semibold).monospacedDigit() }
                    if let left = summary.left {
                        LabeledContent(left >= 0 ? "Left of budget" : "Over budget") {
                            Text(abs(left).money).monospacedDigit().foregroundStyle(left >= 0 ? Color.primary : Color.brandPink)
                        }
                    }
                    LabeledContent("Per day") { Text(summary.perDay.money).monospacedDigit() }
                    LabeledContent("Card fees") { Text(summary.fees.money).monospacedDigit().foregroundStyle(summary.fees > 0 ? Color.brandAmber : .secondary) }
                    if let currency = trip.currency, summary.foreignTotal > 0 {
                        LabeledContent("Paid in \(currency)") { Text(summary.foreignTotal, format: .currency(code: currency)).monospacedDigit() }
                    }
                    if let rate = summary.averageRate, let currency = trip.currency {
                        LabeledContent("Average rate") { Text("\(rate.formatted()) \(currency) to \(AppSettings.currency)").monospacedDigit() }
                    }
                } header: {
                    Text(trip.dates)
                } footer: {
                    if summary.fees > 0 {
                        Text("Fees are what your cards charged for paying in another currency. A card without foreign fees would have saved \(summary.fees.money).")
                    }
                }
                if !summary.byCategory.isEmpty {
                    Section("By category") {
                        ForEach(summary.byCategory, id: \.category) { row in
                            LabeledContent(row.category) { Text(row.amount.money).monospacedDigit() }
                        }
                    }
                }
                Section {
                    ForEach(summary.payments) { payment in
                        DeletableRow(label: "Take Off Trip", onDelete: { store.removeFromTrip(payment, trip: trip) }) {
                            NavigationLink { TransactionEditor(transaction: payment) } label: { TripPaymentRow(payment: payment) }
                        }
                    }
                    if !suggestions.isEmpty {
                        Button {
                            store.setTrip(trip, for: suggestions.map(\.id))
                        } label: {
                            Label("Add \(suggestions.count) More Payment\(suggestions.count == 1 ? "" : "s") From These Dates", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Payments")
                } footer: {
                    Text("Add flights or hotels paid earlier from the payment itself (Trip, in its details).")
                }
            }
            .navigationTitle(trip.name)
            .toolbar { Button("Edit") { editing = true } }
            .sheet(isPresented: $editing) { NavigationStack { TripEditor(trip: trip) } }
        } else {
            ContentUnavailableView("Trip deleted", systemImage: "airplane")
        }
    }
}

struct TripPaymentRow: View {
    let payment: BankTransaction

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(payment.merchant).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text((-payment.amountAfterReimbursement).money).monospacedDigit()
        }
    }

    private var subtitle: String {
        var parts = [payment.date.formatted(.dateTime.day().month(.abbreviated))]
        if let foreign = payment.foreign {
            parts.append(foreign.amount.formatted(.currency(code: foreign.currency)))
            if let rate = foreign.rate(homeAmount: payment.amount) { parts.append("at \(rate.formatted())") }
        }
        if TripLedger.isCardFee(payment) { parts.append("card fee") }
        return parts.joined(separator: " · ")
    }
}

struct TripEditor: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State var trip: Trip

    private var isNew: Bool { !store.trips.contains { $0.id == trip.id } }
    static let currencies = ["EUR", "USD", "CHF", "JPY", "AUD", "CAD", "NZD", "SEK", "NOK", "DKK", "PLN", "CZK", "TRY", "AED", "INR", "THB", "SGD", "HKD", "ZAR", "MXN", "GBP"]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $trip.name, prompt: Text("e.g. Lisbon, August"))
                DatePicker("First day", selection: $trip.start, displayedComponents: .date)
                DatePicker("Last day", selection: $trip.end, in: trip.start..., displayedComponents: .date)
                Picker("Currency there", selection: $trip.currency) {
                    Text("Same as home").tag(String?.none)
                    ForEach(Self.currencies.filter { $0 != AppSettings.currency }, id: \.self) { code in
                        Text("\(code) – \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(String?.some(code))
                    }
                }
                TextField("Budget (optional)", value: $trip.budget, format: .number).decimalKeyboard()
                if store.hasPartner {
                    Picker("Whose", selection: Binding(get: { trip.owner ?? .shared }, set: { trip.owner = $0 })) {
                        ForEach(MoneyOwner.allCases, id: \.self) { Text($0.label(partnerName: store.couple.partnerName)).tag($0) }
                    }
                }
                PrivateToggle(isPrivate: $trip.isPrivate)
            }
            if !isNew {
                DeleteSection(title: "Delete Trip", message: "Its payments stay, just not on a trip.") {
                    store.deleteTrip(trip)
                    dismiss()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New trip" : trip.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if trip.end < trip.start { trip.end = trip.start }
                    store.saveTrip(trip)
                    dismiss()
                }
                .disabled(trip.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// In a payment's editor: which trip it's on, and what it cost in the other currency.
struct TripAndCurrencySection: View {
    @EnvironmentObject var store: BudgetStore
    @Binding var transaction: BankTransaction

    var body: some View {
        if transaction.amount < 0 {
            Section {
                if !store.trips.isEmpty {
                    Picker("Trip", selection: $transaction.tripID) {
                        Text(automaticTrip.map { "\($0.name) (by its dates)" } ?? "None").tag(UUID?.none)
                        ForEach(store.trips) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Toggle("Paid in another currency", isOn: Binding(
                    get: { transaction.foreign != nil },
                    set: { on in transaction.foreign = on ? ForeignAmount(amount: 0, currency: automaticTrip?.currency ?? "EUR") : nil }
                ))
                if transaction.foreign != nil {
                    HStack {
                        TextField("Amount there", value: Binding(get: { transaction.foreign?.amount ?? 0 }, set: { transaction.foreign?.amount = $0 }), format: .number)
                            .decimalKeyboard()
                        Picker("Currency", selection: Binding(get: { transaction.foreign?.currency ?? "EUR" }, set: { transaction.foreign?.currency = $0 })) {
                            ForEach(TripEditor.currencies.filter { $0 != AppSettings.currency }, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    TextField("Card fee included (optional)", value: Binding(get: { transaction.foreign?.fee }, set: { transaction.foreign?.fee = $0 }), format: .number)
                        .decimalKeyboard()
                }
            } header: {
                Text("Travel")
            } footer: {
                if let foreign = transaction.foreign, let rate = foreign.rate(homeAmount: transaction.amount) {
                    Text("Rate \(rate.formatted()) \(foreign.currency) to \(AppSettings.currency)" + ((foreign.fee ?? 0) > 0 ? ", not counting the fee." : "."))
                } else {
                    Text("Put flights and hotels paid before you went on the trip here.")
                }
            }
        }
    }

    private var automaticTrip: Trip? {
        var unassigned = transaction
        unassigned.tripID = nil
        return store.trips.first { !TripLedger.payments(for: $0, in: [unassigned], calendar: store.calculator.calendar).isEmpty }
    }
}
