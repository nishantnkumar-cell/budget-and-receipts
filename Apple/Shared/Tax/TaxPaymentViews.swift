import BudgetCore
import SwiftUI
import TaxCore

/// How a payment's tax status reads in a list.
struct TaxStatusLine: View {
    let status: PaymentStatus
    let covered: Bool
    let properties: [RentalProperty]

    var body: some View {
        if covered {
            Text("Counted through an agent statement").font(.caption).foregroundStyle(.tint)
        } else {
            switch status {
            case .notProperty: EmptyView()
            case .needsReview: Text("Needs a look for tax").font(.caption).foregroundStyle(.orange)
            case .assigned(let id, let category, let source):
                Text("\(name(id)) · \(category.title)\(source == .byRule ? " · rule" : "")").font(.caption).foregroundStyle(.tint)
            case .parts(let parts):
                Text("\(parts.count) part\(parts.count == 1 ? "" : "s") for property").font(.caption).foregroundStyle(.tint)
            }
        }
    }

    private func name(_ id: String) -> String { properties.first { $0.id == id }?.name ?? "Unknown property" }
}

/// The tax year's payments, to mark against a property.
struct TaxPaymentsView: View {
    private enum Filter: String, CaseIterable {
        case all = "All", property = "Property", review = "To review"
    }

    private struct Row: Identifiable {
        let payment: BankTransaction
        let status: PaymentStatus
        let covered: Bool
        var id: String { payment.id }
    }

    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @State private var filter = Filter.all
    @State private var search = ""
    @State private var selected: BankTransaction?

    private var rows: [Row] {
        let book = tax.book
        let choices = PaymentClassifier.index(book.assignments)
        let covered = Set(book.statements.compactMap(\.bankFingerprint))
        return store.transactions.compactMap { payment in
            guard tax.year.contains(payment.date) else { return nil }
            if !search.isEmpty && !payment.matches(search) { return nil }
            let row = Row(payment: payment, status: PaymentClassifier.classify(payment, book: book, assignments: choices),
                          covered: covered.contains(payment.id))
            switch filter {
            case .all: return row
            case .property: return row.covered || row.status != .notProperty ? row : nil
            case .review:
                if case .needsReview = row.status, !row.covered { return row }
                return nil
            }
        }
    }

    var body: some View {
        let rows = rows
        List {
            Section {
                TaxYearPicker()
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section {
                if rows.isEmpty { Text("Nothing in \(tax.year.description) matches.").foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    Button { selected = row.payment } label: { label(row) }
                        .buttonStyle(.plain)
                        .disabled(row.covered)
                }
            }
        }
        .searchable(text: $search, prompt: "Shop, person or category")
        .navigationTitle("Property Payments")
        .sheet(item: $selected) { TaxAssignView(payment: $0) }
    }

    private func label(_ row: Row) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.payment.merchant)
                Text("\(PropertyLedger.day(row.payment.date)) · \(row.payment.category)").font(.caption).foregroundStyle(.secondary)
                TaxStatusLine(status: row.status, covered: row.covered, properties: tax.book.properties)
            }
            Spacer()
            Text(row.payment.amount.money)
                .monospacedDigit()
                .foregroundStyle(row.payment.amount > 0 ? .green : .primary)
        }
        .contentShape(Rectangle())
    }
}

/// Which property a payment (or each part of a split one) belongs to, and what kind of money
/// it is.
struct TaxAssignView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @Environment(\.dismiss) private var dismiss
    let payment: BankTransaction

    /// Empty property means "not for property".
    private struct Choice: Equatable {
        var propertyID = ""
        var category = PropertyCategory.repairs
    }

    @State private var whole = Choice()
    @State private var parts: [UUID: Choice] = [:]
    @State private var always = false

    private var isSplit: Bool { !payment.splits.isEmpty }
    private var isPrivate: Bool { store.isPrivate(payment) }

    var body: some View {
        let status = PaymentClassifier.classify(payment, book: tax.book)
        TaxSheet(title: "Property payment", canSave: !tax.book.properties.isEmpty && (isSplit || !whole.propertyID.isEmpty)) {
            save()
        } content: {
            Section {
                LabeledContent(payment.merchant, value: payment.amount.money)
                LabeledContent("Date", value: PropertyLedger.day(payment.date))
            } footer: {
                if isPrivate && store.hasPartner { Text("This payment is private, so your partner won't see this choice.") }
            }
            if tax.book.properties.isEmpty {
                Section { Text("Add a property first, in Property & Tax › Properties and Rules.") }
            } else if isSplit {
                ForEach(payment.splits) { split in
                    Section("\(split.label) · \(split.amount.money)") {
                        picker(Binding(get: { parts[split.id] ?? Choice() }, set: { parts[split.id] = $0 }), optional: true)
                    }
                }
            } else {
                Section {
                    picker($whole, optional: false)
                    Toggle("Always treat \(payment.merchant) this way", isOn: $always)
                } footer: {
                    Text(footer)
                }
                if status != .notProperty {
                    Section {
                        Button("Not for tax", role: .destructive) {
                            tax.change { $0.exclude(payment) }
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear { start(status) }
    }

    @ViewBuilder private func picker(_ choice: Binding<Choice>, optional: Bool) -> some View {
        Picker("Property", selection: choice.propertyID) {
            if optional { Text("Not property").tag("") }
            ForEach(tax.book.properties) { Text($0.name).tag($0.id) }
        }
        if !choice.wrappedValue.propertyID.isEmpty {
            Picker("Kind", selection: choice.category) {
                ForEach(PropertyCategory.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private func start(_ status: PaymentStatus) {
        let usual = Choice(propertyID: isSplit ? "" : tax.book.properties.first?.id ?? "",
                           category: payment.amount > 0 ? .rent : .repairs)
        whole = usual
        for split in payment.splits { parts[split.id] = usual }
        switch status {
        case .assigned(let id, let category, _): whole = Choice(propertyID: id, category: category)
        case .parts(let chosen):
            for part in chosen { parts[part.split.id] = Choice(propertyID: part.propertyID, category: part.category) }
        case .notProperty, .needsReview: break
        }
    }

    private func save() {
        // As the payment is now: it may have synced a change while this was open.
        let payment = store.transactions.first { $0.id == payment.id } ?? payment
        let isSplit = !payment.splits.isEmpty
        tax.change { book in
            if isSplit {
                for split in payment.splits {
                    let choice = parts[split.id] ?? Choice()
                    book.assign(part: split.id, of: payment,
                                to: choice.propertyID.isEmpty ? nil : (choice.propertyID, choice.category))
                }
                // Every part left out of a payment a rule or tag would pull back in.
                if !book.assignments.contains(where: { $0.fingerprint == payment.id }) { book.exclude(payment) }
            } else if always {
                book.addRule(from: payment, to: whole.propertyID, as: whole.category, isPrivate: isPrivate)
            } else {
                book.assign(payment, to: whole.propertyID, as: whole.category)
            }
        }
    }

    private var footer: String {
        if always {
            let probe = PropertyRule(merchantContains: payment.merchant, propertyID: whole.propertyID, category: whole.category)
            return "A rule for every payment whose name contains this: \(store.transactions.filter(probe.matches).count) now."
        }
        return switch whole.category {
        case .mortgagePayment: "Not counted. Enter the lender's yearly interest figure under Pay and Statements."
        case .capital: "Buying or improving isn't an expense against rent."
        case .ignore: "Left out of the property figures."
        default: "Only this payment."
        }
    }
}

/// On a payment's own screen: its property, and a way to set it.
struct TaxPaymentSection: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @AppStorage(AppSettings.taxEnabledKey) private var enabled = false
    let transactionID: String
    @State private var selected: BankTransaction?

    var body: some View {
        if enabled, let payment = store.transactions.first(where: { $0.id == transactionID }) {
            Section {
                let covered = tax.book.statements.contains { $0.bankFingerprint == payment.id }
                TaxStatusLine(status: PaymentClassifier.classify(payment, book: tax.book), covered: covered, properties: tax.book.properties)
                if !covered {
                    Button { selected = payment } label: { Label("Property and Tax…", systemImage: "house") }
                }
            } header: {
                Text("Property")
            } footer: {
                Text("Uses the payment as last saved.")
            }
            .sheet(item: $selected) { TaxAssignView(payment: $0) }
        }
    }
}
