import BudgetCore
import SwiftUI

/// "‹ October 2026 ›" control that changes the month shown on Overview and Budgets.
struct MonthSwitcher: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        HStack {
            Button { store.moveMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Text(store.selectedMonth, format: .dateTime.month(.wide).year())
                .font(.headline)
                .frame(minWidth: 140)
            Button { store.moveMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel("Next month")
        }
        .buttonStyle(.borderless)
    }
}

struct BudgetsView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var editing: String?
    @State private var limitText = ""

    /// Every budgetable category, including ones with no budget and no spending yet.
    private func lines(_ report: MonthlyBudgetReport) -> [CategoryBudgetLine] {
        FinanceCategories.budgetable.map { category in
            report.lines.first { $0.category == category } ?? CategoryBudgetLine(category: category, limit: nil, spent: 0)
        }
    }

    private func startEditing(_ line: CategoryBudgetLine) {
        editing = line.category
        limitText = line.limit.map { "\($0)" } ?? ""
    }

    var body: some View {
        let report = store.monthReport
        List {
            Section {
                HStack {
                    Spacer()
                    MonthSwitcher()
                    Spacer()
                }
                LabeledContent("Spent this month") { Text(report.spending, format: .currency(code: AppSettings.currency)) }
                LabeledContent("Income this month") { Text(report.income, format: .currency(code: AppSettings.currency)) }
            }
            Section("Categories") {
                ForEach(lines(report)) { line in
                    BudgetRow(line: line) { startEditing(line) }
                }
            }
        }
        .navigationTitle("Budgets")
        .alert("Monthly limit for \(editing ?? "")", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Amount", text: $limitText).decimalKeyboard()
            Button("Save") {
                if let category = editing, let limit = AmountParser.parse(limitText, decimalComma: false), limit >= 0 {
                    store.setBudget(category: category, limit: limit, month: store.selectedMonth)
                }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        } message: {
            Text("Applies from \(store.selectedMonth.formatted(.dateTime.month(.wide).year())) until you change it.")
        }
    }
}

struct BudgetRow: View {
    let line: CategoryBudgetLine
    let onEdit: () -> Void

    private var barColour: Color {
        guard let progress = line.progress else { return .secondary }
        if progress > 1 { return .brandPink }
        if progress > 0.85 { return .brandAmber }
        return .brandIndigo
    }

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(line.category).foregroundStyle(.primary)
                    Spacer()
                    Text(line.spent, format: .currency(code: AppSettings.currency)).monospacedDigit()
                    if let limit = line.limit {
                        Text("of \(limit.formatted(.currency(code: AppSettings.currency)))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let progress = line.progress {
                    ProgressView(value: min(progress, 1))
                        .tint(barColour)
                    if let remaining = line.remaining {
                        Text(remaining < 0 ? "\((-remaining).formatted(.currency(code: AppSettings.currency))) over" : "\(remaining.formatted(.currency(code: AppSettings.currency))) left")
                            .font(.caption)
                            .foregroundStyle(remaining < 0 ? Color.brandPink : .secondary)
                    }
                } else {
                    Text("No limit set. Tap to add one.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Set the monthly limit")
    }
}
