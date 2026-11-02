import BudgetCore
import Charts
import SwiftUI

extension WealthAccount.Kind {
    var symbol: String {
        switch self {
        case .cash: "banknote"
        case .savings: "building.columns"
        case .investment: "chart.line.uptrend.xyaxis"
        case .pension: "beach.umbrella"
        case .property: "house"
        case .mortgage: "key.horizontal"
        case .loan: "doc.text"
        case .creditCard: "creditcard"
        case .other: "square.stack.3d.up"
        }
    }
}

/// Home (iPhone): net worth, how it has moved, and a nudge when balances are out of date.
struct NetWorthCard: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        if !store.wealthAccounts.isEmpty {
            NavigationLink { NetWorthView() } label: {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(title: "Net worth") {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.netWorth.wholeMoney)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            NetWorthChangeText()
                        }
                        Spacer()
                        NetWorthSparkline().frame(width: 110, height: 40)
                    }
                    StaleBalancesLine()
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }
}

/// "+£2,180 this month" or "−£300 this month", from the last two points of the trend.
struct NetWorthChangeText: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        let trend = store.netWorthTrend
        if trend.count > 1, let last = trend.last?.total {
            let change = last - trend[trend.count - 2].total
            Label("\(change >= 0 ? "+" : "−")\(abs(change).wholeMoney) this month",
                  systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(change >= 0 ? Color.green : Color.red)
        }
    }
}

struct NetWorthSparkline: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        let trend = store.netWorthTrend
        if trend.count > 1 {
            Chart(Array(trend.enumerated()), id: \.offset) { point in
                LineMark(x: .value("Month", point.element.month), y: .value("Net worth", NSDecimalNumber(decimal: point.element.total).doubleValue))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.brandPink)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .accessibilityHidden(true)
        }
    }
}

/// "2 balances need updating", shown only when some are over a month old.
struct StaleBalancesLine: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        let stale = store.staleWealthAccounts.count
        if stale > 0 {
            Label(stale == 1 ? "1 balance needs updating" : "\(stale) balances need updating", systemImage: "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(Color.brandAmber)
        }
    }
}

/// Assets and debts: the total, what it's made of, and every account to update.
struct NetWorthView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var editing: WealthAccount?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.netWorth.wholeMoney)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    NetWorthChangeText()
                    trendChart.frame(height: 140).padding(.top, 6)
                    StaleBalancesLine()
                }
                .padding(.vertical, 6)
            }
            Section("What it's made of") {
                ForEach(store.netWorthByGroup, id: \.group) { row in
                    LabeledContent(row.group.title) {
                        Text(row.amount.wholeMoney).monospacedDigit().foregroundStyle(row.amount < 0 ? Color.red : Color.primary)
                    }
                }
            }
            if store.hasPartner {
                Section("Whose") {
                    ForEach(MoneyOwner.allCases, id: \.self) { owner in
                        if let amount = store.netWorthByOwner[owner] {
                            LabeledContent(owner.label(partnerName: store.couple.partnerName)) {
                                Text(amount.wholeMoney).monospacedDigit()
                            }
                        }
                    }
                }
            }
            ForEach(WealthAccount.Group.allCases, id: \.self) { group in
                let accounts = store.wealthAccounts.filter { $0.kind.group == group }
                if !accounts.isEmpty {
                    Section(group.title) {
                        ForEach(accounts) { account in
                            Button { editing = account } label: { WealthAccountRow(account: account) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .overlay {
            if store.wealthAccounts.isEmpty {
                ContentUnavailableView {
                    Label("Track what you own and owe", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("Add pensions, savings, investments, your home and mortgage. Update their values now and then to see your net worth grow.")
                } actions: {
                    Button("Add an Account") { editing = WealthAccount(name: "", kind: .savings) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Net worth")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = WealthAccount(name: "", kind: .savings) } label: { Label("Add Account", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { account in
            NavigationStack { WealthAccountEditor(account: account) }
                #if os(macOS)
                .frame(minWidth: 440, minHeight: 520)
                #endif
        }
    }

    @ViewBuilder private var trendChart: some View {
        let trend = store.netWorthTrend
        if trend.count > 1 {
            Chart(Array(trend.enumerated()), id: \.offset) { point in
                AreaMark(x: .value("Month", point.element.month), y: .value("Net worth", NSDecimalNumber(decimal: point.element.total).doubleValue))
                    .foregroundStyle(Color.brandPink.opacity(0.12))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Month", point.element.month), y: .value("Net worth", NSDecimalNumber(decimal: point.element.total).doubleValue))
                    .foregroundStyle(Color.brandPink)
                    .interpolationMethod(.monotone)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel { if let amount = value.as(Double.self) { Text(amount, format: .currency(code: AppSettings.currency).notation(.compactName)) } }
                }
            }
        }
    }
}

struct WealthAccountRow: View {
    @EnvironmentObject var store: BudgetStore
    let account: WealthAccount

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: account.kind.symbol, tint: account.kind.isDebt ? .brandPartner : .brandPlum, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(account.needsUpdate() ? Color.brandAmber : .secondary)
            }
            Spacer()
            if let latest = account.latest {
                Text((account.kind.isDebt ? -latest.amount : latest.amount).wholeMoney)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [account.kind.title]
        if let latest = account.latest {
            parts.append(account.needsUpdate() ? "Update due, last \(latest.date.formatted(.dateTime.day().month(.abbreviated)))"
                                                : "Updated \(latest.date.formatted(.dateTime.day().month(.abbreviated)))")
        } else {
            parts.append("No value yet")
        }
        if account.kind.isDebt, let payoff = store.netWorthCalculator.payoffDate(account) {
            parts.append("Paid off \(payoff.formatted(.dateTime.month(.abbreviated).year()))")
        }
        if account.kind == .property {
            parts.append("Equity \(store.netWorthCalculator.equity(of: account, accounts: store.wealthAccounts).wholeMoney)")
        }
        return parts.joined(separator: " · ")
    }
}

/// Add or change an asset or debt, and record today's value.
struct WealthAccountEditor: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State var account: WealthAccount
    @State private var newValue: Decimal?
    @State private var confirmingDelete = false

    private var isNew: Bool { !store.wealthAccounts.contains { $0.id == account.id } }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $account.name, prompt: Text("e.g. Workplace pension"))
                Picker("Type", selection: $account.kind) {
                    ForEach(WealthAccount.Kind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                if store.hasPartner {
                    Picker("Whose", selection: Binding(get: { account.owner ?? .mine }, set: { account.owner = $0 })) {
                        ForEach(MoneyOwner.allCases, id: \.self) { Text($0.label(partnerName: store.couple.partnerName)).tag($0) }
                    }
                }
                PrivateToggle(isPrivate: $account.isPrivate)
            }
            Section {
                TextField(account.kind.isDebt ? "Amount owed today" : "Value today", value: $newValue, format: .number)
                    .decimalKeyboard()
            } header: {
                Text(account.latest == nil ? "Value" : "Update the value")
            } footer: {
                if let latest = account.latest {
                    Text("Last \(latest.amount.money) on \(latest.date.formatted(date: .abbreviated, time: .omitted)).")
                } else if account.kind.isDebt {
                    Text("Enter what you owe as a positive number.")
                }
            }
            if account.kind.isDebt {
                Section {
                    TextField("Interest rate, % a year", value: Binding(
                        get: { account.repayment.map { $0.annualRate * 100 } },
                        set: { rate in account.repayment = rate.map { WealthAccount.Repayment(annualRate: $0 / 100, monthlyPayment: account.repayment?.monthlyPayment ?? 0) } }
                    ), format: .number)
                    .decimalKeyboard()
                    TextField("Monthly payment", value: Binding(
                        get: { account.repayment?.monthlyPayment },
                        set: { payment in account.repayment = payment.map { WealthAccount.Repayment(annualRate: account.repayment?.annualRate ?? 0, monthlyPayment: $0) } }
                    ), format: .number)
                    .decimalKeyboard()
                } header: {
                    Text("Repayments")
                } footer: {
                    if let payoff = store.netWorthCalculator.payoffDate(account) {
                        Text("At this rate it's paid off in \(payoff.formatted(.dateTime.month(.wide).year())).")
                    } else {
                        Text("Add the rate and monthly payment to see when it's paid off.")
                    }
                }
                if account.kind == .mortgage {
                    let homes = store.wealthAccounts.filter { $0.kind == .property }
                    if !homes.isEmpty {
                        Picker("Secured on", selection: $account.propertyID) {
                            Text("None").tag(UUID?.none)
                            ForEach(homes) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
            }
            if account.balances.count > 1 {
                Section("History") {
                    ForEach(account.balances.sorted { $0.date > $1.date }, id: \.date) { balance in
                        LabeledContent(balance.date.formatted(date: .abbreviated, time: .omitted)) {
                            Text(balance.amount.money).monospacedDigit()
                        }
                    }
                }
            }
            if !isNew {
                Section {
                    Button("Delete Account", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New account" : account.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(account.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .alert("Delete \(account.name)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.deleteWealthAccount(account)
                dismiss()
            }
        } message: {
            Text("Its value history goes too.")
        }
    }

    private func save() {
        store.saveWealthAccount(account)
        if let newValue { store.recordBalance(newValue, for: account.id) }
        dismiss()
    }
}
