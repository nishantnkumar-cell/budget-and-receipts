import BudgetCore
import SwiftUI
import TaxCore
import UniformTypeIdentifiers

extension BudgetStore {
    /// One person's forms for the tax year on screen, from everything on this device.
    func returnPack(_ person: Person, tax: TaxStore, india: IndiaStore) -> ReturnPack {
        var ledger = propertyLedger(tax)
        if india.unreadableCount > 0 {
            ledger.issues.append(.init(message: "\(india.unreadableCount) India Accounts items can't be read. Update the app on this device.", blocksFiling: true))
        }
        var pack = ReturnPack.make(person, year: tax.year, ledger: ledger, book: tax.book, india: india.book,
                                   sharedHousehold: householdRole != .solo)
        // The same thing is only said once.
        var seen = Set<String>()
        pack.problems = pack.problems.filter { seen.insert($0).inserted }
        return pack
    }
}

/// Soft copies of one person's return: a box-by-box sheet, and HMRC's forms filled in.
struct ReturnCopiesSection: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @EnvironmentObject var india: IndiaStore
    let person: Person
    @State private var sheet: ExportDocument?
    @State private var failure: String?

    var body: some View {
        let pack = store.returnPack(person, tax: tax, india: india)
        let name = store.taxPeople.first { $0.person == person }?.name ?? ""
        Section {
            if pack.forms.isEmpty {
                ForEach(pack.problems, id: \.self) { Text($0).foregroundStyle(.secondary) }
            } else {
                Button("Box-by-Box Sheet (PDF)", systemImage: "list.bullet.rectangle") {
                    sheet = ExportDocument(data: ReturnSheetPDF.render(pack, name: name == "You" ? "your figures" : name), type: .pdf)
                }
                NavigationLink { ReturnFormsView(person: person) } label: { Label("Fill HMRC Forms", systemImage: "doc.richtext") }
                if let failure { Text(failure).foregroundStyle(.orange) }
            }
        } header: {
            Text("Copies for HMRC")
        } footer: {
            Text("Nothing is sent. Copy the figures into HMRC's online service, or print the filled forms. These files aren't encrypted.")
        }
        .fileExporter(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } }), document: sheet,
                      contentType: .pdf, defaultFilename: "Tax return \(tax.year) \(name) sheet.pdf") { result in
            if case .failure(let error) = result { failure = error.localizedDescription }
        }
    }
}

/// Choose HMRC's blank forms, and get them back filled in.
struct ReturnFormsView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @EnvironmentObject var india: IndiaStore
    let person: Person
    @State private var blanks: [ReturnFormKind: ReturnFormFiller.Blank] = [:]
    @State private var choosing = false
    @State private var filled: ExportDocument?
    @State private var messages: [String] = []

    var body: some View {
        let pack = store.returnPack(person, tax: tax, india: india)
        let needed = ReturnFormKind.allCases.filter { kind in pack.forms.contains { $0.kind == kind } }
        let name = store.taxPeople.first { $0.person == person }?.name ?? ""
        Form {
            if !pack.problems.isEmpty {
                Section("Not ready to file") {
                    ForEach(pack.problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                }
            }
            Section {
                ForEach(needed, id: \.self) { kind in
                    LabeledContent {
                        if let blank = blanks[kind] {
                            Label("Chosen", systemImage: blank.isCheckedVersion ? "checkmark.circle" : "exclamationmark.circle")
                                .foregroundStyle(blank.isCheckedVersion ? Color.green : Color.orange)
                        } else {
                            Link("Get from GOV.UK", destination: kind.download)
                        }
                    } label: {
                        Text("\(kind.rawValue) \(kind.title)")
                    }
                }
                ForEach(needed.filter { blanks[$0]?.isCheckedVersion == false }, id: \.self) { kind in
                    Text("Your \(kind.rawValue) differs from the copy this app was checked against. Look carefully at where each figure lands.")
                        .font(.callout).foregroundStyle(.orange)
                }
                Button("Choose Blank Forms", systemImage: "doc.badge.plus") { choosing = true }
                ForEach(messages, id: \.self) { Text($0).foregroundStyle(.orange) }
            } header: {
                Text("1. Blank 2025-26 forms")
            } footer: {
                Text("Download each form as a PDF, then choose them all here. The app doesn't fetch anything itself.")
            }
            Section {
                Button("Save Filled Forms", systemImage: "square.and.arrow.down") {
                    do {
                        filled = ExportDocument(data: try ReturnFormFiller.fill(pack, blanks: blanks), type: .pdf)
                    } catch {
                        messages = [error.localizedDescription]
                    }
                }
                .disabled(needed.isEmpty || !needed.allSatisfy { blanks[$0] != nil })
            } header: {
                Text("2. Filled forms")
            } footer: {
                Text("Your name, tax reference, National Insurance number and signature are left for you.")
            }
            if !pack.checks.isEmpty {
                Section("Before you send them") {
                    ForEach(pack.checks, id: \.self) { Text($0) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("HMRC Forms")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { load($0) }
        .fileExporter(isPresented: Binding(get: { filled != nil }, set: { if !$0 { filled = nil } }), document: filled,
                      contentType: .pdf, defaultFilename: "Tax return \(tax.year) \(name) forms.pdf") { result in
            if case .failure(let error) = result { messages = [error.localizedDescription] }
        }
    }

    private func load(_ result: Result<[URL], Error>) {
        messages = []
        switch result {
        case .failure(let error): messages = [error.localizedDescription]
        case .success(let urls):
            for url in urls {
                guard let data = try? UploadFile.data(url), let blank = ReturnFormFiller.identify(data) else {
                    messages.append("\(url.lastPathComponent) isn't a blank 2025-26 SA100, SA102, SA105 or SA106.")
                    continue
                }
                blanks[blank.kind] = blank
            }
        }
    }
}
