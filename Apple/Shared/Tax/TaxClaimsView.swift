import BudgetCore
import SwiftUI
import TaxCore

/// Every relief and allowance for one person, with the rule, the amounts and what to do.
struct TaxClaimsView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @EnvironmentObject var india: IndiaStore
    @State private var person = Person.me

    var body: some View {
        let claims = TaxClaim.list(person, year: tax.year, ledger: store.propertyLedger(tax), book: tax.book, india: india.book)
        let groups = claims.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        let open = claims.filter { $0.status == .open }
        Form {
            Section {
                TaxYearPicker()
                Picker("Whose", selection: $person) {
                    ForEach(store.taxPeople, id: \.person) { Text($0.name).tag($0.person) }
                }
                .pickerStyle(.segmented)
                if !open.isEmpty {
                    Label("Worth a look: \(open.map(\.title).joined(separator: ", "))", systemImage: "lightbulb").foregroundStyle(.orange)
                }
            }
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(claims.filter { $0.group == group }) { claim in
                        DisclosureGroup {
                            Text(claim.rule).font(.callout)
                            ForEach(claim.lines, id: \.label) { line in
                                LabeledContent(line.label, value: TaxMoney.format(line.amount))
                            }
                            if !claim.action.isEmpty { Text(claim.action).font(.footnote).foregroundStyle(.secondary) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(claim.title)
                                Text(claim.status.rawValue + (claim.worth.map { " · worth \(TaxMoney.format($0))" } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(claim.status == .open ? Color.orange : Color.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                Text("Amounts come only from what's entered in the app. “Worth” is how much more tax there would be without it. \(TaxNotes.notCovered)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Reliefs and Claims")
    }
}
