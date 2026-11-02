import BudgetCore
import SwiftUI

/// Budgets: the month's totals, then every category with what's left. Tap one to set its limit.
struct BudgetsView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var editing: CategoryBudgetLine?

    /// Every budgetable category, including ones with no budget and no spending yet.
    private func lines(_ report: MonthlyBudgetReport) -> [CategoryBudgetLine] {
        FinanceCategories.budgetable.map { category in
            report.lines.first { $0.category == category } ?? CategoryBudgetLine(category: category, limit: nil, spent: 0)
        }
    }

    var body: some View {
        let report = store.monthReport
        let budgeted = report.lines.compactMap(\.limit).reduce(0, +)
        ScrollView {
            VStack(spacing: Theme.spacing) {
                HouseholdSwitcher()
                HStack {
                    Spacer()
                    MonthSwitcher()
                }
                HStack(spacing: 10) {
                    SummaryTile(title: "Budgeted", amount: budgeted)
                    SummaryTile(title: "Spent", amount: report.spending)
                    SummaryTile(title: "Income", amount: report.income, tint: .green)
                }
                NavigationLink { MonthReviewView() } label: {
                    HStack(spacing: 12) {
                        IconBadge(systemImage: "calendar.badge.checkmark", size: 32)
                        Text("\(store.selectedMonth.formatted(.dateTime.month(.wide))) in review").font(.body.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .card(padding: 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                VStack(spacing: 0) {
                    ForEach(lines(report)) { line in
                        Button { editing = line } label: {
                            BudgetProgressRow(line: line)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Set the monthly limit")
                        if line.id != lines(report).last?.id { Divider() }
                    }
                }
                .card(padding: 16)
                if report.lines.contains(where: \.isTentative) {
                    Label("Tentative budgets are your 3-month average. Tap one to set your own limit.", systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .appBackground()
        .navigationTitle("Budgets")
        .sheet(item: $editing) { line in
            BudgetLimitSheet(line: line)
        }
    }
}

struct SummaryTile: View {
    let title: String
    let amount: Decimal
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(amount.money)
                .font(.headline)
                .foregroundStyle(tint)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Sets a category's monthly limit and whether leftover money rolls into next month.
struct BudgetLimitSheet: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let line: CategoryBudgetLine
    @State private var limitText = ""
    @State private var rollover = false

    /// The rollover setting of the budget in force for the month being viewed.
    private var currentRollover: Bool {
        store.budgets
            .filter { $0.category == line.category && $0.month <= store.selectedMonth }
            .max { $0.month < $1.month }?
            .rollover ?? false
    }

    private var limit: Decimal? {
        guard let value = AmountParser.parse(limitText, decimalComma: false), value >= 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Monthly limit", text: $limitText).decimalKeyboard()
                    Toggle("Roll over leftover money", isOn: $rollover)
                } footer: {
                    Text("Applies from \(store.selectedMonth.formatted(.dateTime.month(.wide).year())) until you change it. With roll over on, money you don't spend is added to next month's limit.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(line.category)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let limit {
                            store.setBudget(category: line.category, limit: limit, month: store.selectedMonth, rollover: rollover)
                        }
                        dismiss()
                    }
                    .disabled(limit == nil)
                }
            }
        }
        .onAppear {
            limitText = line.limit.map { "\($0)" } ?? ""
            rollover = currentRollover
        }
        .presentationDetents([.medium])
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 240)
        #endif
    }
}
