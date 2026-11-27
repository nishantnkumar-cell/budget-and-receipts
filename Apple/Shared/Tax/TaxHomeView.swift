import BudgetCore
import SwiftUI
import TaxCore

/// Property & Tax: where the year stands, and the way to each part.
struct TaxHomeView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @EnvironmentObject var india: IndiaStore

    var body: some View {
        let ledger = store.propertyLedger(tax)
        let blocking = ledger.issues.filter(\.blocksFiling)
        let notes = ledger.issues.filter { !$0.blocksFiling }
        let lost = PropertyLedger.lostAssignments(transactions: store.transactions, book: tax.book)
        Form {
            Section {
                TaxYearPicker()
                NavigationLink { TaxPaymentsView() } label: { Label("Property Payments", systemImage: "creditcard") }
                NavigationLink { TaxPropertiesView() } label: { Label("Properties and Rules", systemImage: "house") }
                NavigationLink { TaxFiguresView() } label: { Label("Pay and Statements", systemImage: "square.and.pencil") }
                NavigationLink { TaxReturnView() } label: { Label("Return Figures", systemImage: "doc.text") }
                NavigationLink { TaxClaimsView() } label: { Label("Reliefs and Claims", systemImage: "checklist") }
                NavigationLink { TaxCompareView() } label: { Label("Whose Name to Buy In?", systemImage: "person.2") }
            }
            if tax.book.properties.isEmpty {
                Section {
                    Text("Start by adding a property in Properties and Rules. Then mark its rent and costs in Property Payments.")
                }
            }
            if !blocking.isEmpty {
                Section("Not ready to file") {
                    ForEach(blocking, id: \.self) { Label($0.message, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                }
            }
            if !lost.isEmpty {
                Section {
                    Button("Forget \(lost.count) choice\(lost.count == 1 ? "" : "s") for payments that are gone", role: .destructive) {
                        let ids = Set(lost.map(\.id))
                        tax.change { book in book.assignments.removeAll { ids.contains($0.id) } }
                    }
                } footer: {
                    Text("Only do this after marking their replacements, and once everything has synced.")
                }
            }
            ForEach(store.taxPeople, id: \.person) { entry in
                let input = PersonInput.make(entry.person, ledger: ledger, book: tax.book, year: tax.year, india: india.book)
                let result = TaxCalculator.estimate(input)
                // Pay or savings alone is enough to estimate: no property needed.
                if !tax.book.properties.isEmpty || result.pay > 0 || result.interest > 0 || result.dividends > 0 || result.pensionAllowance != nil
                    || input.isMissingRate {
                    Section(blocking.isEmpty ? "\(entry.name): estimate" : "\(entry.name): provisional estimate") {
                        LabeledContent("Taxable property profit", value: TaxMoney.format(result.pages.taxableProfit))
                        if result.interest > 0 { LabeledContent("Interest", value: TaxMoney.format(result.interest)) }
                        if result.dividends > 0 { LabeledContent("Dividends", value: TaxMoney.format(result.dividends)) }
                        if result.pensionCharge > 0 {
                            LabeledContent("Pension charge, included below", value: TaxMoney.format(result.pensionCharge - result.pensionSchemePaid))
                        }
                        if input.isMissingRate {
                            Label("Income from India is left out until you enter the rupees to a pound for \(tax.year.description) in India Accounts.", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                        LabeledContent("Tax for the year", value: TaxMoney.format(result.liability))
                        LabeledContent(result.balance < 0 ? "Refund due" : "Still to pay", value: TaxMoney.format(abs(result.balance)))
                        if let advance = result.paymentOnAccount {
                            LabeledContent("Plus two advance payments, each", value: TaxMoney.format(advance))
                        }
                    }
                }
            }
            if !notes.isEmpty {
                Section("Worth checking") {
                    ForEach(notes, id: \.self) { Text($0.message) }
                }
            }
            Section {
                Text(TaxNotes.notCovered).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppSection.tax.rawValue)
    }
}
