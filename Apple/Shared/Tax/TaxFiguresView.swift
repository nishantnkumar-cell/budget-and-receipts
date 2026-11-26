import BudgetCore
import SwiftUI
import TaxCore

/// The figures bank payments can't supply.
struct TaxFiguresView: View {
    private enum Sheet: Identifiable {
        case pay(TaxPay), statement(AgentStatement), interest(MortgageInterest), figures(YearFigures)

        var id: String {
            switch self {
            case .pay(let item): item.id
            case .statement(let item): item.id
            case .interest(let item): item.id
            case .figures(let item): item.id
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
                    row("\(name(job.person)): \(job.employer)", job.taxablePay, enteredBy: job.enteredBy) { sheet = .pay(job) }
                }
                Button("Add Pay", systemImage: "plus") {
                    sheet = .pay(TaxPay(person: .me, taxYear: year, employer: "", taxablePay: 0, taxDeducted: 0))
                }
                NavigationLink { PayslipImportView() } label: { Label("Import Payslips", systemImage: "square.and.arrow.down") }
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
                    NavigationLink { LettingImportView() } label: { Label("Import Agent Statements", systemImage: "square.and.arrow.down") }
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
            Section {
                ForEach(book.figures.filter { $0.taxYear == year }) { entry in
                    let entered = entry.losses + entry.financeCosts + entry.advancePaid + entry.giftAid
                        + (entry.ukInterest ?? 0) + (entry.ukDividends ?? 0) + (entry.pension?.paidIn ?? 0)
                    row(name(entry.person), entered, enteredBy: entry.enteredBy) {
                        sheet = .figures(entry)
                    }
                }
                ForEach(store.taxPeople, id: \.person) { entry in
                    if !book.figures.contains(where: { $0.person == entry.person && $0.taxYear == year }) {
                        Button("Add for \(entry.name)", systemImage: "plus") {
                            sheet = .figures(YearFigures(person: entry.person, taxYear: year))
                        }
                    }
                }
            } header: {
                Text("Savings, pension, brought forward, advance payments and Gift Aid")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Pay and Statements")
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .pay(let item): TaxPayEditor(job: item)
            case .statement(let item): TaxStatementEditor(statement: item)
            case .interest(let item): TaxInterestEditor(figure: item)
            case .figures(let item): TaxYearFiguresEditor(figures: item)
            }
        }
    }

    /// An entry your partner typed in can be read here but only changed by them.
    private func row(_ title: String, _ amount: Decimal?, enteredBy: Person = .me, open: @escaping () -> Void) -> some View {
        let theirs = enteredBy == .partner
        return Button(action: open) {
            LabeledContent {
                Text(amount.map(TaxMoney.format) ?? "Not entered")
            } label: {
                Text(title)
                if theirs { Text("Entered by \(name(.partner)). Only they can change it.").font(.caption) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(theirs)
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
    @State private var travel = ""
    @State private var flatRate = ""
    @State private var subscriptions = ""
    @State private var otherExpense = ""
    @State private var shared = false
    /// Whether it was already saved when the sheet opened.
    @State private var existed = false

    var body: some View {
        let values = [pay, deducted, pension, travel, flatRate, subscriptions, otherExpense].map(TaxAmountField.value)
        let exists = tax.book.pay.contains { $0.id == job.id }
        TaxSheet(title: "Pay", canSave: !employer.isEmpty && !values.contains(nil)) {
            // Saved by hand, the figures count as typed in (no payslip date): you've checked them.
            var entered = TaxPay(id: job.id, person: person, taxYear: job.taxYear, employer: employer, taxablePay: values[0]!,
                                 taxDeducted: values[1]!, reliefAtSourcePension: values[2]!, isShared: shared, enteredBy: job.enteredBy)
            let expenses = JobExpenses(travel: values[3]!, flatRate: values[4]!, subscriptions: values[5]!, other: values[6]!)
            entered.expenses = expenses == JobExpenses() ? nil : expenses
            tax.change { book in
                var saved = entered
                let current = book.pay.first { $0.id == saved.id }
                // Removed on another device while the sheet was open: it stays removed.
                if existed && current == nil { return }
                // Sharing is written only when the switch was changed here, so a sheet left
                // open never shares again what another device has since made private.
                if shared == job.isShared, let current { saved.isShared = current.isShared }
                book.pay.removeAll { $0.id == saved.id }
                book.pay.append(saved)
            }
        } content: {
            Section {
                Picker("Whose", selection: $person) {
                    ForEach(store.taxPeople, id: \.person) { Text($0.name).tag($0.person) }
                }
                TextField("Employer", text: $employer, prompt: Text("Employer or umbrella company"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("Employer")
                TaxAmountField(title: "Taxable pay", text: $pay)
                TaxAmountField(title: "Tax deducted", text: $deducted)
            } footer: {
                Text("From the P60, or the year's last payslip. Add taxable benefits that weren't taxed through payroll. Tax deducted can include tax for earlier years: check your tax code.")
            }
            Section {
                TaxAmountField(title: "Pension paid yourself", text: $pension)
            } footer: {
                Text("Only a pension paid from take-home pay (“relief at source”), including the basic-rate relief added. Salary sacrifice and net pay pensions are already taken out of taxable pay.")
            }
            Section {
                TaxAmountField(title: "Professional fees and subscriptions", text: $subscriptions)
                TaxAmountField(title: "Business travel", text: $travel)
                TaxAmountField(title: "Flat rate expenses", text: $flatRate)
                TaxAmountField(title: "Other job expenses", text: $otherExpense)
            } header: {
                Text("Expenses you can claim")
            } footer: {
                Text("Only what you paid for this job and weren't repaid. Property & Tax, Reliefs and Claims explains each one. Keep receipts.")
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
            travel = TaxAmountField.text(job.expenses?.travel ?? 0)
            flatRate = TaxAmountField.text(job.expenses?.flatRate ?? 0)
            subscriptions = TaxAmountField.text(job.expenses?.subscriptions ?? 0)
            otherExpense = TaxAmountField.text(job.expenses?.other ?? 0)
            shared = job.isShared
            existed = tax.book.pay.contains { $0.id == job.id }
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

private struct TaxYearFiguresEditor: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    let figures: YearFigures
    @State private var losses = ""
    @State private var finance = ""
    @State private var advance = ""
    @State private var giftAid = ""
    @State private var interest = ""
    @State private var dividends = ""
    @State private var paidIn = ""
    @State private var sacrificed = ""
    @State private var unused = ""
    @State private var schemePays = ""
    @State private var shared = false
    /// Whether it was already saved when the sheet opened.
    @State private var existed = false

    var body: some View {
        let values = [losses, finance, advance, giftAid, interest, dividends, paidIn, sacrificed, unused, schemePays].map(TaxAmountField.value)
        TaxSheet(title: "Other figures, \(figures.taxYear)", canSave: !values.contains(nil)) {
            var saved = figures
            saved.losses = values[0]!
            saved.financeCosts = values[1]!
            saved.advancePaid = values[2]!
            saved.giftAid = values[3]!
            saved.ukInterest = values[4]! == 0 ? nil : values[4]
            saved.ukDividends = values[5]! == 0 ? nil : values[5]
            let pension = PensionYear(paidIn: values[6]!, sacrificed: values[7]!, unused: values[8]!, schemePays: values[9]!)
            saved.pension = pension == PensionYear(paidIn: 0) ? nil : pension
            saved.isShared = shared
            tax.change { book in
                var saved = saved
                let current = book.figures.first { $0.id == saved.id }
                // As for pay: removed figures stay removed, and only a changed switch is written.
                if existed && current == nil { return }
                if shared == figures.isShared, let current { saved.isShared = current.isShared }
                book.figures.removeAll { $0.id == saved.id }
                if !saved.isBlank { book.figures.append(saved) }
            }
        } content: {
            Section {
                TaxAmountField(title: "Interest from UK banks", text: $interest)
                TaxAmountField(title: "Dividends from UK companies", text: $dividends)
            } header: {
                Text("Savings this year")
            } footer: {
                Text("This person's share, for the whole tax year. Leave out ISAs. Interest from India comes from India Accounts.")
            }
            Section {
                TaxAmountField(title: "Paid into pensions", text: $paidIn)
                TaxAmountField(title: "Of which salary sacrifice", text: $sacrificed)
                TaxAmountField(title: "Unused allowance brought forward", text: $unused)
                TaxAmountField(title: "Charge your scheme pays", text: $schemePays)
            } header: {
                Text("Pension this year")
            } footer: {
                Text("Paid in: everything for the tax year from you and your employers, including salary sacrifice and tax relief. For a defined benefit pension, use your scheme's savings statement. Unused allowance is what's left from the three earlier years, from your scheme's statements or HMRC's calculator.")
            }
            Section {
                TaxAmountField(title: "Property losses", text: $losses)
                TaxAmountField(title: "Unused finance costs", text: $finance)
            } header: {
                Text("From last year's return")
            } footer: {
                Text("This person's own amounts from last year's UK property pages.")
            }
            Section {
                TaxAmountField(title: "Advance payments made", text: $advance)
                TaxAmountField(title: "Gift Aid, with tax added", text: $giftAid)
            } header: {
                Text("This year")
            } footer: {
                Text("Advance payments are the payments on account already paid towards this year's bill. For Gift Aid, enter what you gave multiplied by 1.25.")
            }
            if store.hasPartner {
                Section { Toggle("Show to \(store.taxPeople[1].name)", isOn: $shared) }
            }
        }
        .onAppear {
            losses = TaxAmountField.text(figures.losses)
            finance = TaxAmountField.text(figures.financeCosts)
            advance = TaxAmountField.text(figures.advancePaid)
            giftAid = TaxAmountField.text(figures.giftAid)
            interest = TaxAmountField.text(figures.ukInterest ?? 0)
            dividends = TaxAmountField.text(figures.ukDividends ?? 0)
            paidIn = TaxAmountField.text(figures.pension?.paidIn ?? 0)
            sacrificed = TaxAmountField.text(figures.pension?.sacrificed ?? 0)
            unused = TaxAmountField.text(figures.pension?.unused ?? 0)
            schemePays = TaxAmountField.text(figures.pension?.schemePays ?? 0)
            shared = figures.isShared
            existed = tax.book.figures.contains { $0.id == figures.id }
        }
    }
}
