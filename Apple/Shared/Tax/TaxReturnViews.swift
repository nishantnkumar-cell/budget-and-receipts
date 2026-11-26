import BudgetCore
import SwiftUI
import TaxCore

/// The figures to copy into the return, one person at a time.
struct TaxReturnView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @EnvironmentObject var india: IndiaStore
    @State private var person = Person.me
    @State private var sheet: ExportDocument?
    @State private var saveFailure: String?

    var body: some View {
        let ledger = store.propertyLedger(tax)
        let result = TaxCalculator.estimate(.make(person, ledger: ledger, book: tax.book, year: tax.year, india: india.book))
        let jobs = tax.book.pay.filter { $0.person == person && $0.taxYear == tax.year.description }
        Form {
            Section {
                TaxYearPicker()
                Picker("Whose return", selection: $person) {
                    ForEach(store.taxPeople, id: \.person) { Text($0.name).tag($0.person) }
                }
                .pickerStyle(.segmented)
                if ledger.issues.contains(where: \.blocksFiling) {
                    Label("Not ready to file: see Property & Tax.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
            ReturnCopiesSection(person: person, sheet: $sheet)
            if let saveFailure { Section { Text(saveFailure).foregroundStyle(.orange) } }
            if !jobs.isEmpty {
                Section("Employment page") {
                    ForEach(jobs) { job in
                        LabeledContent("\(job.employer): pay", value: TaxMoney.format(job.taxablePay))
                        LabeledContent("\(job.employer): tax taken off", value: TaxMoney.format(job.taxDeducted))
                    }
                }
            }
            Section("UK property pages (SA105 box numbers, 2025-26 form)") {
                ForEach(result.pages.boxes, id: \.box) { box in
                    LabeledContent {
                        Text(box.value).monospacedDigit().textSelection(.enabled)
                    } label: {
                        Text("\(box.box)  \(box.title)")
                    }
                }
            }
            Section("Estimate") {
                LabeledContent("Adjusted net income", value: TaxMoney.format(result.adjustedNetIncome))
                LabeledContent("Personal allowance", value: TaxMoney.format(result.personalAllowance))
                if result.interest > 0 {
                    LabeledContent("Interest (from India \(TaxMoney.format(result.foreignInterest)))", value: TaxMoney.format(result.interest))
                    LabeledContent("Tax on the interest", value: TaxMoney.format(result.savingsTax))
                }
                if result.dividends > 0 {
                    LabeledContent("Dividends", value: TaxMoney.format(result.dividends))
                    LabeledContent("Tax on the dividends", value: TaxMoney.format(result.dividendTax))
                }
                LabeledContent("Income tax", value: TaxMoney.format(result.taxBeforeReduction))
                LabeledContent("Less finance cost relief", value: TaxMoney.format(result.financeReduction))
                if result.foreignRelief > 0 {
                    LabeledContent("Less relief for tax taken in India", value: TaxMoney.format(result.foreignRelief))
                }
                LabeledContent("Tax for the year", value: TaxMoney.format(result.liability))
                LabeledContent("Already deducted from pay", value: TaxMoney.format(result.taxDeducted))
                if result.advancePaid > 0 {
                    LabeledContent("Advance payments made", value: TaxMoney.format(result.advancePaid))
                }
                LabeledContent(result.balance < 0 ? "Refund due" : "Still to pay", value: TaxMoney.format(abs(result.balance)))
                if let advance = result.paymentOnAccount {
                    LabeledContent("Plus two advance payments, each", value: TaxMoney.format(advance))
                }
                if result.financeCarriedForward > 0 {
                    LabeledContent("Finance costs carried forward", value: TaxMoney.format(result.financeCarriedForward))
                }
            }
            Section {
                Text(TaxNotes.notCovered).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Return Figures")
        .fileExporter(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } }), document: sheet,
                      contentType: .pdf,
                      defaultFilename: "Tax return \(tax.year) \(store.taxPeople.first { $0.person == person }?.name ?? "") sheet.pdf") { result in
            if case .failure(let error) = result { saveFailure = error.localizedDescription }
        }
    }
}

struct TaxCompareView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @EnvironmentObject var india: IndiaStore
    @State private var rent = ""
    @State private var expenses = ""
    @State private var interest = ""

    var body: some View {
        let values = [rent, expenses, interest].map(TaxAmountField.value)
        let ledger = store.propertyLedger(tax)
        let names = store.taxPeople
        Form {
            Section { TaxYearPicker() }
            Section("A new property, per year") {
                TaxAmountField(title: "Rent", text: $rent)
                TaxAmountField(title: "Expenses", text: $expenses)
                TaxAmountField(title: "Mortgage interest", text: $interest)
            }
            if !values.contains(nil), values[0]! > 0 {
                let options = OwnershipComparison.compare(
                    NewProperty(yearlyRent: values[0]!, yearlyExpenses: values[1]!, yearlyInterest: values[2]!),
                    me: .make(.me, ledger: ledger, book: tax.book, year: tax.year, india: india.book),
                    partner: .make(.partner, ledger: ledger, book: tax.book, year: tax.year, india: india.book))
                Section {
                    ForEach(options, id: \.myShare) { option in
                        LabeledContent(option.myShare == 1 ? "Your name" : option.myShare == 0 ? "\(names[1].name)'s name" : "Half each",
                                       value: TaxMoney.format(option.total))
                    }
                } header: {
                    Text("Extra income tax in \(tax.year.description), cheapest first")
                } footer: {
                    Text("Uses the pay and property figures entered for \(tax.year.description), so enter both people's pay. Stamp duty and capital gains tax aren't included.")
                }
                if ledger.issues.contains(where: \.blocksFiling) {
                    Section { Text("Some current figures still need review, so treat this as provisional.").foregroundStyle(.orange) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Whose Name?")
    }
}
