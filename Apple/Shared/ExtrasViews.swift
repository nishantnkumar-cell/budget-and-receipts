import BudgetCore
import SwiftUI

/// Comments and quick reactions on a transaction, so you two can talk about a payment.
struct TransactionNotesSection: View {
    @EnvironmentObject var store: BudgetStore
    let transaction: BankTransaction
    @State private var draft = ""

    static let reactions = ["👍", "❤️", "😮", "🤔"]

    var body: some View {
        Section {
            ForEach(store.notes(for: transaction)) { note in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(note.author == .me ? Color.brandPlum : Color.brandPartner)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(note.author == .me ? "You" : store.couple.partnerName).font(.subheadline.weight(.semibold))
                            Text(note.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        }
                        if !note.text.isEmpty { Text(note.text) }
                        if let reaction = note.reaction { Text(reaction).font(.title3) }
                    }
                }
                .swipeActions { Button("Delete", role: .destructive) { store.deleteNote(note) } }
                .contextMenu { Button("Delete", role: .destructive) { store.deleteNote(note) } }
            }
            HStack(spacing: 8) {
                TextField("Add a comment", text: $draft, axis: .vertical)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send comment")
            }
            HStack(spacing: 6) {
                ForEach(Self.reactions, id: \.self) { reaction in
                    Button(reaction) { store.addNote(to: transaction, reaction: reaction) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
        } header: {
            Text("Comments")
        } footer: {
            if store.hasPartner { Text("\(store.couple.partnerName) sees these when you share your household.") }
        }
    }

    private func send() {
        store.addNote(to: transaction, text: draft)
        draft = ""
    }
}

/// Plan: how much to put aside each month so yearly and quarterly bills don't hurt.
struct SetAsidesSection: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore

    var body: some View {
        let plan = store.setAsides(contracts: subscriptions.contracts)
        if !plan.isEmpty {
            Section {
                ForEach(plan) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.vendor).fontWeight(.semibold)
                            Text("\(item.amount.money) due \(item.dueDate.formatted(.dateTime.day().month(.abbreviated).year()))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(item.monthly.money) a month").fontWeight(.semibold).monospacedDigit()
                    }
                }
                LabeledContent("Put aside in total") {
                    Text(plan.reduce(0) { $0 + $1.monthly }.money).fontWeight(.bold).monospacedDigit()
                }
            } header: {
                Label("Put aside each month", systemImage: "tray.and.arrow.down")
            } footer: {
                Text("For bills that come once a quarter or once a year, so the money is there when they land.")
            }
        }
    }
}

/// A short look back at the month: in and out, what changed, and anything over budget.
struct MonthReviewView: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        let review = store.monthReview
        List {
            Section {
                LabeledContent("Money in") { Text(review.income.money).monospacedDigit().foregroundStyle(.green) }
                LabeledContent("Spent") { Text(review.spending.money).monospacedDigit().fontWeight(.semibold) }
                if review.previousSpending > 0 {
                    let change = review.spendingChange
                    Label(change <= 0 ? "\((-change).money) less than last month" : "\(change.money) more than last month",
                          systemImage: change <= 0 ? "arrow.down.right.circle.fill" : "arrow.up.right.circle.fill")
                        .foregroundStyle(change <= 0 ? Color.green : Color.red)
                }
            }
            if !review.topCategories.isEmpty {
                Section("Where it went") {
                    ForEach(review.topCategories, id: \.category) { row in
                        HStack {
                            Text(row.category)
                            Spacer()
                            if row.previous > 0 {
                                Text("\(row.change >= 0 ? "+" : "−")\(abs(row.change).money)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(row.change > 0 ? Color.red : Color.green)
                            }
                            Text(row.spent.money).fontWeight(.semibold).monospacedDigit()
                        }
                    }
                }
            }
            if !review.overBudget.isEmpty {
                Section("Over budget") {
                    ForEach(review.overBudget, id: \.self) { category in
                        Label(category, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    }
                }
            }
            if let biggest = review.biggestPurchase {
                Section("Biggest purchase") { TransactionRow(transaction: biggest) }
            }
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationTitle("\(review.month.formatted(.dateTime.month(.wide))) in review")
    }
}

/// Tags for a transaction, e.g. "work trip" or "wedding", typed with commas between them.
struct TransactionTagsSection: View {
    @EnvironmentObject var store: BudgetStore
    @Binding var tags: [String]
    @State private var text = ""

    var body: some View {
        Section {
            TextField("Add tags, e.g. work trip", text: $text)
                .onSubmit(commit)
                .onAppear { text = tags.joined(separator: ", ") }
                .onChange(of: text) { _, _ in commit() }
            let suggestions = store.allTags.filter { !tags.contains($0) }.prefix(6)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(suggestions), id: \.self) { tag in
                            Button { text = (tags + [tag]).joined(separator: ", ") } label: {
                                Label(tag, systemImage: "tag")
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                        }
                    }
                }
            }
        } header: {
            Text("Tags")
        } footer: {
            Text("Separate tags with commas. Use them for expense reports, like a work trip.")
        }
    }

    private func commit() {
        tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Settings › Reports: spending between two dates, optionally for one tag, to share as CSV.
struct ExpenseReportView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var tag: String?
    @State private var exporting = false

    var body: some View {
        let report = store.expenseReport(from: from, to: to, tag: tag)
        Form {
            Section {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
                Picker("Tag", selection: $tag) {
                    Text("Everything").tag(String?.none)
                    ForEach(store.allTags, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            Section {
                LabeledContent("Total") { Text(report.total.money).fontWeight(.bold).monospacedDigit() }
                LabeledContent("Payments") { Text("\(report.transactions.count)") }
                ForEach(report.byCategory, id: \.category) { row in
                    LabeledContent(row.category) { Text(row.amount.money).monospacedDigit() }
                }
            }
            Section {
                Button { exporting = true } label: { Label("Export as CSV", systemImage: "square.and.arrow.up") }
                    .disabled(report.transactions.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Expense report")
        .fileExporter(isPresented: $exporting, document: ExportDocument(data: Data(report.csv().utf8), type: .commaSeparatedText),
                      contentType: .commaSeparatedText, defaultFilename: "Expenses\(tag.map { " \($0)" } ?? "").csv") { _ in }
    }
}

/// One line under the Home hero: where the current account is heading by month end.
struct BalanceForecastLine: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore

    var body: some View {
        if let forecast = store.balanceForecast(contracts: subscriptions.contracts) {
            Label {
                Text(forecast.goesOverdrawn
                     ? "Heading for \(forecast.endOfMonth.money) by month end. Bills of \(forecast.billsToCome.money) are still to come."
                     : "Heading for \(forecast.endOfMonth.money) by month end, after \(forecast.billsToCome.money) of bills.")
            } icon: {
                Image(systemName: forecast.goesOverdrawn ? "exclamationmark.triangle.fill" : "chart.line.flattrend.xyaxis")
                    .foregroundStyle(forecast.goesOverdrawn ? Color.red : Color.brandPink)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
