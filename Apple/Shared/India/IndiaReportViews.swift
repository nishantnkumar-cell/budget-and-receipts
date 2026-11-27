import BudgetCore
import SwiftUI
import TaxCore
import UniformTypeIdentifiers

/// Interest and Indian tax for a UK tax year, per person, in rupees and pounds.
struct IndiaReportView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var india: IndiaStore
    @State private var person = Person.me
    @State private var rate = ""
    @State private var exporting = false

    var body: some View {
        let report = IndiaReport.make(india.book, year: india.year, person: person)
        Form {
            Section {
                Picker("Tax year", selection: $india.year) {
                    ForEach(TaxYear.supported, id: \.self) { Text($0.description).tag($0) }
                }
                Picker("Whose", selection: $person) {
                    ForEach(store.taxPeople, id: \.person) { Text($0.name).tag($0.person) }
                }
                IndiaRateField(title: "Rupees to £1", rateID: india.year.description)
            } footer: {
                Text(india.year.indianYearsNote)
            }
            if !report.warnings.isEmpty {
                Section("Check first") {
                    ForEach(report.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                }
            }
            if store.householdRole != .solo {
                Section { Text("Accounts your partner keeps private aren't included on this device.") }
            }
            ForEach(report.rows) { row in
                Section {
                    IndiaAmountRow(title: "Interest, before tax", rupees: row.interest, rate: report.rupeesPerPound)
                    IndiaAmountRow(title: "Tax deducted in India", rupees: row.taxDeducted, rate: report.rupeesPerPound)
                    if row.dividends != 0 || row.dividendTax != 0 {
                        IndiaAmountRow(title: "Dividends, before tax", rupees: row.dividends, rate: report.rupeesPerPound)
                        IndiaAmountRow(title: "Tax deducted on dividends", rupees: row.dividendTax, rate: report.rupeesPerPound)
                    }
                } header: {
                    Text(row.account.title)
                } footer: {
                    if let first = row.firstLine, let last = row.lastLine {
                        Text("Statement lines from \(PropertyLedger.day(first)) to \(PropertyLedger.day(last)).")
                    } else {
                        Text("No statement lines in this year.")
                    }
                }
            }
            if report.rows.isEmpty {
                Section { Text("No accounts for this person.") }
            } else {
                Section("Total") {
                    IndiaAmountRow(title: "Interest, before tax", rupees: report.interest, rate: report.rupeesPerPound)
                    IndiaAmountRow(title: "Tax deducted in India", rupees: report.taxDeducted, rate: report.rupeesPerPound)
                    if report.dividends != 0 || report.dividendTax != 0 {
                        IndiaAmountRow(title: "Dividends, before tax", rupees: report.dividends, rate: report.rupeesPerPound)
                        IndiaAmountRow(title: "Tax deducted on dividends", rupees: report.dividendTax, rate: report.rupeesPerPound)
                    }
                    Button("Export for Your Accountant", systemImage: "square.and.arrow.up") { exporting = true }
                }
            }
            Section {
                Text(IndiaNotes.report).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Income for UK Tax")
        .fileExporter(isPresented: $exporting, document: ExportDocument(data: Data(report.csv(india.book).utf8), type: .commaSeparatedText),
                      contentType: .commaSeparatedText, defaultFilename: "India income \(report.year).csv") { _ in }
    }
}

enum IndiaNotes {
    static let report = "UK residents are normally taxed on interest wherever it arises, including NRE interest that India doesn't tax; some recent arrivals can claim relief. On the foreign pages (SA106) interest goes in before Indian tax. Relief for that tax is limited to the rate in the India–UK treaty, which can be less than the bank deducted. Dividends go in before tax too; India may take no more than 10% of ordinary dividends. Property & Tax adds the interest and dividends to its estimate. Not tax advice."
}

/// One exchange rate, saved as it's typed.
struct IndiaRateField: View {
    @EnvironmentObject var india: IndiaStore
    let title: String
    let rateID: String
    @State private var text = ""

    var body: some View {
        IndiaAmountField(title: title, text: $text)
            .onChange(of: rateID, initial: true) { text = india.book.rate(rateID).map { "\($0)" } ?? "" }
            // A rate arriving from another device shows unless it's what is typed already.
            .onChange(of: india.book.rate(rateID)) {
                let saved = india.book.rate(rateID)
                if saved != IndiaMoney.parse(text) { text = saved.map { "\($0)" } ?? "" }
            }
            .onChange(of: text) {
                guard text.isEmpty || IndiaMoney.parse(text) != nil else { return }
                let value = IndiaMoney.parse(text)
                if value != india.book.rate(rateID) { india.change { $0.setRate(rateID, rupeesPerPound: value) } }
            }
    }
}

struct IndiaRatesView: View {
    var body: some View {
        Form {
            Section {
                IndiaRateField(title: "Rupees to £1 today", rateID: IndiaRate.balancesID)
            } footer: {
                Text("Used to show balances in pounds.")
            }
            Section {
                ForEach(TaxYear.supported, id: \.self) { year in
                    IndiaRateField(title: "Average for \(year.description)", rateID: year.description)
                }
            } footer: {
                Text("Used for interest. HMRC publishes yearly average rates each March on GOV.UK; ask your accountant which to use. The app doesn't look rates up.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Exchange Rates")
    }
}
