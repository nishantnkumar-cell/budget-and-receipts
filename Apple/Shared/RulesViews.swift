import BudgetCore
import SwiftUI

/// Settings › Categories and rules: the rules that categorise payments, in the order they're
/// tried. Your own rules come first; the starter rules can be turned off or changed.
struct RulesView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var editing: CategoryRule?
    @State private var result: String?

    private var ownRules: [CategoryRule] { store.rules.filter { !$0.isStarter } }
    private var starterRules: [CategoryRule] { store.rules.filter(\.isStarter) }

    var body: some View {
        List {
            Section {
                Button {
                    let changed = store.applyRules()
                    result = changed == 0 ? "Everything already matches your rules." : "Updated \(changed) payment\(changed == 1 ? "" : "s")."
                } label: {
                    Label("Apply Rules to Uncategorised Payments", systemImage: "wand.and.stars")
                }
                if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Rules are tried from the top and the first that matches decides. They come before what the app has learned and before Apple Intelligence. Categories you've set yourself are never changed here.")
            }
            Section("Your rules") {
                if ownRules.isEmpty {
                    Text("None yet. Add one here, or from any payment with Make a Rule.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(ownRules) { rule in
                    RuleRow(rule: rule) { editing = rule }
                }
                .onDelete { offsets in offsets.map { ownRules[$0] }.forEach(store.deleteRule) }
                .onMove { source, destination in
                    // Moves within your own rules, which sit at the top of the list.
                    store.moveRules(fromOffsets: source, toOffset: destination)
                }
            }
            Section {
                ForEach(starterRules) { rule in
                    RuleRow(rule: rule) { editing = rule }
                }
            } header: {
                Text("Starter rules")
            } footer: {
                Text("Common UK banks' wording and well-known shops. Turn off any you don't want.")
            }
        }
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = CategoryRule(name: "", conditions: [.init(.description, .contains)], category: FinanceCategories.resolve("Groceries")) } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            #endif
        }
        .sheet(item: $editing) { rule in
            NavigationStack { RuleEditor(rule: rule) }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
        }
    }
}

struct RuleRow: View {
    @EnvironmentObject var store: BudgetStore
    let rule: CategoryRule
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle(rule.name, isOn: Binding(get: { rule.isEnabled }, set: { enabled in
                var changed = rule
                changed.isEnabled = enabled
                store.saveRule(changed)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name.isEmpty ? "Untitled rule" : rule.name).fontWeight(.semibold)
                    Text(rule.conditions.map(\.summary).joined(separator: rule.matchAll ? " and " : " or "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Label(rule.resultLabel, systemImage: "arrow.turn.down.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.brandPink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .opacity(rule.isEnabled ? 1 : 0.55)
    }
}

/// Make or change a rule: what to look for, and the category (and sub-category) it gives.
/// Shows the payments it matches as you type.
struct RuleEditor: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State var rule: CategoryRule
    @State private var applyNow = true

    private var isNew: Bool { !store.rules.contains { $0.id == rule.id } }

    var body: some View {
        let matches = store.matches(for: rule)
        Form {
            Section {
                TextField("Name", text: $rule.name, prompt: Text("e.g. Weekly shop"))
                Picker("When", selection: $rule.matchAll) {
                    Text("All of these match").tag(true)
                    Text("Any of these match").tag(false)
                }
            }
            Section {
                ForEach($rule.conditions.indices, id: \.self) { index in
                    DeletableRow(label: "Delete Condition", onDelete: { rule.conditions.remove(at: index) }) {
                        ConditionRow(condition: $rule.conditions[index])
                    }
                }
                .onDelete { rule.conditions.remove(atOffsets: $0) }
                Button { rule.conditions.append(.init(.description, .contains)) } label: {
                    Label("Add Condition", systemImage: "plus.circle")
                }
            } header: {
                Text("Conditions")
            } footer: {
                Text("Words match whole, ignoring capitals and punctuation. For \"contains any of\", separate words with commas.")
            }
            Section("Then") {
                CategoryPickers(category: $rule.category, subcategory: $rule.subcategory)
            }
            Section {
                if matches.isEmpty {
                    Text("No payments match yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(matches.prefix(5)) { TransactionRow(transaction: $0) }
                    if matches.count > 5 { Text("and \(matches.count - 5) more").font(.caption).foregroundStyle(.secondary) }
                    Toggle("Recategorise these \(matches.count) payments now", isOn: $applyNow)
                }
            } header: {
                Text("Matches \(matches.count) payment\(matches.count == 1 ? "" : "s")")
            }
            if !isNew {
                Section {
                    Button(rule.isStarter ? "Turn Off Rule" : "Delete Rule", role: .destructive) {
                        store.deleteRule(rule)
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New rule" : "Edit rule")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = rule.resultLabel }
                    store.saveRule(rule)
                    if applyNow { store.apply(rule) }
                    dismiss()
                }
                .disabled(rule.conditions.isEmpty || rule.conditions.contains { $0.op.needsValue && $0.value.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
    }
}

struct ConditionRow: View {
    @Binding var condition: CategoryRule.Condition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Field", selection: $condition.field) {
                    ForEach(CategoryRule.Field.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("Test", selection: $condition.op) {
                    ForEach(CategoryRule.Operator.available(for: condition.field), id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if condition.op.needsValue {
                TextField(condition.field == .amount ? "Amount" : "Text", text: $condition.value)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
            }
        }
        .onChange(of: condition.field) { _, field in
            if !CategoryRule.Operator.available(for: field).contains(condition.op) {
                condition.op = CategoryRule.Operator.available(for: field)[0]
            }
        }
    }
}

/// Category and, when it has them, sub-category.
struct CategoryPickers: View {
    @Binding var category: String
    @Binding var subcategory: String?

    var body: some View {
        Picker("Category", selection: $category) {
            ForEach(FinanceCategories.all, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: category) { _, newValue in
            if let sub = subcategory, !FinanceCategories.subcategories(of: newValue).contains(sub) { subcategory = nil }
        }
        let subs = FinanceCategories.subcategories(of: category)
        if !subs.isEmpty {
            Picker("Sub-category", selection: $subcategory) {
                Text("None").tag(String?.none)
                ForEach(subs, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        }
    }
}

/// In a payment's detail: turn this payment's category into a rule for the same shop.
struct MakeRuleButton: View {
    let transaction: BankTransaction
    @State private var draft: CategoryRule?

    var body: some View {
        Button {
            draft = RulesEngine.rule(from: transaction, category: transaction.category == "Uncategorised" ? FinanceCategories.resolve("Groceries") : transaction.category, subcategory: transaction.subcategory)
        } label: {
            Label("Make a Rule for Payments Like This", systemImage: "wand.and.stars")
        }
        .sheet(item: $draft) { rule in
            NavigationStack { RuleEditor(rule: rule) }
                #if os(macOS)
                .frame(minWidth: 520, minHeight: 560)
                #endif
        }
    }
}

/// Where the money in one category went this month, by sub-category.
struct SubcategoryBreakdown: View {
    @EnvironmentObject var store: BudgetStore
    let category: String

    var body: some View {
        let rows = breakdown
        if rows.count > 1 || rows.first?.name != "Not set" {
            Section("Where it went") {
                ForEach(rows, id: \.name) { row in
                    LabeledContent(row.name) { Text(row.amount.money).monospacedDigit() }
                }
            }
        }
    }

    private var breakdown: [(name: String, amount: Decimal)] {
        var totals: [String: Decimal] = [:]
        for transaction in store.viewTransactions where transaction.category == category && transaction.splits.isEmpty
            && store.calculator.isInMonth(transaction.date, store.selectedMonth) {
            totals[transaction.subcategory ?? "Not set", default: 0] += -transaction.amount
        }
        return totals.filter { $0.value != 0 }.map { (name: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
    }
}
