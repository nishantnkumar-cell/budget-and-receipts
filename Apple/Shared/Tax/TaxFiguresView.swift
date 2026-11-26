import BudgetCore
import SwiftUI
import TaxCore

/// The figures bank payments can't supply.
struct TaxFiguresView: View {
    private enum Sheet: Identifiable {
        case pay(TaxPay), statement(AgentStatement), interest(MortgageInterest), carried(CarriedForward)

        var id: String {
            switch self {
            case .pay(let item): item.id
            case .statement(let item): item.id
            case .interest(let item): item.id
            case .carried(let item): item.id
            }
        }
    }

    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @State private var sheet: Sheet?

    var body: some View {
        let year = tax.year.description
        let book = tax.book
        Form {
            Section { TaxYearPicker() }
            Section {
                ForEach(book.pay.filter { $0.taxYear == year }) { job in
                    row("\(name(job.person)): \(job.employer)", job.taxablePay) { sheet = .pay(job) }
                }
                Button("Add Pay", systemImage: "plus") {
                    sheet = .pay(TaxPay(person: .me, taxYear: year, employer: "", taxablePay: 0, taxDeducted: 0))
                }
            } header: {
                Text("Pay (P60)")
            } footer: {
                if store.hasPartner { Text("Pay is private unless you choose to show it to your partner.") }
            }
            if let first = book.properties.first {
                Section("Letting agent statements") {
                    ForEach(book.statements.filter { tax.year.contains($0.date) }) { statement in
                        row("\(PropertyLedger.day(statement.date)): \(propertyName(statement.propertyID))", statement.grossRent) {
                            sheet = .statement(statement)
                        }
                    }
                    Button("Add Statement", systemImage: "plus") {
                        let today = min(Date(), tax.year.end.addingTimeInterval(-43_200))
                        sheet = .statement(AgentStatement(propertyID: first.id, date: today, grossRent: 0))
                    }
                }
                Section("Mortgage interest for \(year)") {
                    ForEach(book.properties) { property in
                        let entered = book.interest.first { $0.propertyID == property.id && $0.taxYear == year }
                        row(property.name, entered?.interestAndFees) {
                            sheet = .interest(entered ?? MortgageInterest(propertyID: property.id, taxYear: year, interestAndFees: 0))
                        }
                    }
                }
            } else {
                Section { Text("Add a property to enter agent statements and mortgage interest.").foregroundStyle(.secondary) }
            }
            Section("Brought forward from last year's return") {
                ForEach(store.taxPeople, id: \.person) { entry in
                    let entered = book.carried.filter { $0.person == entry.person && $0.taxYear == year }
                    row(entry.name, entered.isEmpty ? nil : entered.reduce(0) { $0 + $1.losses + $1.financeCosts }) {
                        sheet = .carried(entered.first ?? CarriedForward(person: entry.person, taxYear: year))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Pay and Statements")
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .pay(let item): TaxPayEditor(job: item)
            case .statement(let item): TaxStatementEditor(statement: item)
            case .interest(let item): TaxInterestEditor(figure: item)
            case .carried(let item): TaxCarriedEditor(carried: item)
            }
        }
    }

    private func row(_ title: String, _ amount: Decimal?, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            LabeledContent(title, value: amount.map(TaxMoney.format) ?? "Not entered").contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func name(_ person: Person) -> String { store.taxPeople.first { $0.person == person }?.name ?? "" }
    private func propertyName(_ id: String) -> String { tax.book.properties.first { $0.id == id }?.name ?? "Unknown property" }
}

private struct TaxPayEditor: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    let job: TaxPay
    @State private var person = Person.me
    @State private var employer = ""
    @State private var pay = ""
    @State private var deducted = ""
    @State private var pension = ""
    @State private var shared = false

    var body: some View {
        let values = [pay, deducted, pension].map(TaxAmountField.value)
        let exists = tax.book.pay.contains { $0.id == job.id }
        TaxSheet(title: "Pay", canSave: !employer.isEmpty && !values.contains(nil)) {
            let saved = TaxPay(id: job.id, person: person, taxYear: job.taxYear, employer: employer, taxablePay: values[0]!,
                               taxDeducted: values[1]!, reliefAtSourcePension: values[2]!, isShared: shared)
            tax.change { book in
                book.pay.removeAll { $0.id == saved.id }
                book.pay.append(saved)
            }
        } content: {
            Section {
                Picker("Whose", selection: $person) {
                    ForEach(store.taxPeople, id: \.person) { Text($0.name).tag($0.person) }
                }
                TextField("Employer", text: $employer, prompt: Text("Employer or umbrella company"))
                    .accessibilityIdentifier("Employer")
                TaxAmountField(title: "Taxable pay", text: $pay)
                TaxAmountField(title: "Tax deducted", text: $deducted)
            } footer: {
                Text("From the P60, or the year's last payslip.")
            }
            Section {
                TaxAmountField(title: "Pension paid yourself", text: $pension)
            } footer: {
                Text("Only a pension paid from take-home pay (“relief at source”), including the basic-rate relief added. Salary sacrifice and net pay pensions are already taken out of taxable pay.")
            }
            if store.hasPartner {
                Section {
                    Toggle("Show to \(store.taxPeople[1].name)", isOn: $shared)
                } footer: {
                    Text("Turning this off later removes it from their devices, but can't undo what they've already seen.")
                }
            }
            if exists {
                TaxRemoveButton(title: "Remove Pay") { tax.change { book in book.pay.removeAll { $0.id == job.id } } }
            }
        }
        .onAppear {
            person = job.person
            employer = job.employer
            pay = TaxAmountField.text(job.taxablePay)
            deducted = TaxAmountField.text(job.taxDeducted)
            pension = TaxAmountField.text(job.reliefAtSourcePension)
            shared = job.isShared
        }
    }
}

private struct TaxStatementEditor: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    let statement: AgentStatement
    @State private var propertyID = ""
    @State private var date = Date()
    @State private var rent = ""
    @State private var fees = ""
    @State private var repairs = ""
    @State private var other = ""
    @State private var fingerprint = ""

    /// Money received within two weeks of the statement, plus the one already linked.
    private var receipts: [BankTransaction] {
        let taken = Set(tax.book.statements.filter { $0.id != statement.id }.compactMap(\.bankFingerprint))
        return store.transactions.filter {
            $0.id == fingerprint || ($0.amount > 0 && !taken.contains($0.id) && abs($0.date.timeIntervalSince(date)) <= 15 * 86_400)
        }
    }

    var body: some View {
        let values = [rent, fees, repairs, other].map(TaxAmountField.value)
        let exists = tax.book.statements.contains { $0.id == statement.id }
        let net: Decimal? = values.contains(nil) ? nil : values[0]! - values[1]! - values[2]! - values[3]!
        TaxSheet(title: "Agent statement", canSave: net != nil && values[0]! > 0) {
            // Noon in London, so the date is the same day everywhere.
            let day = TaxYear.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            let saved = AgentStatement(id: statement.id, propertyID: propertyID, date: day, grossRent: values[0]!,
                                       fees: values[1]!, repairs: values[2]!, otherExpense: values[3]!,
                                       bankFingerprint: fingerprint.isEmpty ? nil : fingerprint)
            tax.change { book in
                book.statements.removeAll { $0.id == saved.id }
                book.statements.append(saved)
            }
        } content: {
            Section {
                Picker("Property", selection: $propertyID) {
                    ForEach(tax.book.properties) { Text($0.name).tag($0.id) }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TaxAmountField(title: "Rent before deductions", text: $rent)
                TaxAmountField(title: "Agent fees", text: $fees)
                TaxAmountField(title: "Repairs paid by agent", text: $repairs)
                TaxAmountField(title: "Other costs", text: $other)
                if let net { LabeledContent("Paid to you", value: TaxMoney.format(net)) }
            }
            Section {
                Picker("Bank payment", selection: $fingerprint) {
                    Text("Not linked").tag("")
                    ForEach(receipts) {
                        Text("\($0.amount.money) · \(PropertyLedger.day($0.date)) · \($0.merchant)").tag($0.id)
                    }
                }
                if let net, fingerprint.isEmpty, let match = receipts.first(where: { $0.amount == net }) {
                    Button("Link the \(match.amount.money) from \(match.merchant)") { fingerprint = match.id }
                }
            } footer: {
                Text("Linking the money that reached your bank stops it being counted twice.")
            }
            if exists {
                TaxRemoveButton(title: "Remove Statement") { tax.change { book in book.statements.removeAll { $0.id == statement.id } } }
            }
        }
        .onAppear {
            propertyID = statement.propertyID
            date = statement.date
            rent = TaxAmountField.text(statement.grossRent)
            fees = TaxAmountField.text(statement.fees)
            repairs = TaxAmountField.text(statement.repairs)
            other = TaxAmountField.text(statement.otherExpense)
            fingerprint = statement.bankFingerprint ?? ""
        }
    }
}

private struct TaxInterestEditor: View {
    @EnvironmentObject var tax: TaxStore
    let figure: MortgageInterest
    @State private var amount = ""

    var body: some View {
        let value = TaxMoney.parse(amount)
        TaxSheet(title: "Mortgage interest", canSave: value != nil) {
            var saved = figure
            saved.interestAndFees = value ?? 0
            tax.change { book in
                book.interest.removeAll { $0.id == saved.id }
                book.interest.append(saved)
            }
        } content: {
            Section {
                TaxAmountField(title: "Interest and fees, \(figure.taxYear)", text: $amount)
            } footer: {
                Text("From the lender's yearly statement, 6 April to 5 April. Interest and finance charges only, not repayment of the loan.")
            }
            if tax.book.interest.contains(where: { $0.id == figure.id }) {
                TaxRemoveButton(title: "Remove Figure") { tax.change { book in book.interest.removeAll { $0.id == figure.id } } }
            }
        }
        .onAppear { amount = TaxAmountField.text(figure.interestAndFees) }
    }
}

private struct TaxCarriedEditor: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    let carried: CarriedForward
    @State private var losses = ""
    @State private var finance = ""
    @State private var shared = false

    var body: some View {
        let values = [losses, finance].map(TaxAmountField.value)
        TaxSheet(title: "Brought forward", canSave: !values.contains(nil)) {
            let saved = CarriedForward(id: carried.id, person: carried.person, taxYear: carried.taxYear,
                                       losses: values[0]!, financeCosts: values[1]!, isShared: shared)
            tax.change { book in
                book.carried.removeAll { $0.person == saved.person && $0.taxYear == saved.taxYear }
                if saved.losses > 0 || saved.financeCosts > 0 { book.carried.append(saved) }
            }
        } content: {
            Section {
                TaxAmountField(title: "Property losses", text: $losses)
                TaxAmountField(title: "Unused finance costs", text: $finance)
            } footer: {
                Text("This person's own amounts from last year's UK property pages.")
            }
            if store.hasPartner {
                Section { Toggle("Show to \(store.taxPeople[1].name)", isOn: $shared) }
            }
        }
        .onAppear {
            losses = TaxAmountField.text(carried.losses)
            finance = TaxAmountField.text(carried.financeCosts)
            shared = carried.isShared
        }
    }
}
