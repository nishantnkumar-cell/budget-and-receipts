import BudgetCore
import PDFKit
import SwiftUI
import TaxCore
import UniformTypeIdentifiers

/// Why a chosen file couldn't be read at all.
private enum UploadFileError: LocalizedError {
    case locked, noText

    var errorDescription: String? {
        switch self {
        case .locked: "This PDF needs a password. Open it, save a copy without one, and choose that."
        case .noText: "This PDF has no text to read (it may be a scan)."
        }
    }
}

enum UploadFile {
    /// The ways of taking the text out of a PDF: its own order, and row by row as printed.
    @MainActor static func pdfTexts(_ data: Data) throws -> [String] {
        guard let document = PDFDocument(data: data) else { throw UploadFileError.noText }
        guard !document.isLocked else { throw UploadFileError.locked }
        let texts = [document.string ?? "", SharedReceiptReader.visualLines(document).joined(separator: "\n")]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !texts.isEmpty else { throw UploadFileError.noText }
        return texts
    }

    static func data(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}

/// Choose letting agent statements, check what was read, then add them to a property.
struct LettingImportView: View {
    private struct Found: Identifiable {
        let id = UUID()
        let fileName: String
        let statement: LettingStatement
        var propertyID: String
        var include: Bool
    }

    /// What importing would do now.
    private struct Preview {
        var book: PropertyBook
        /// The statement each chosen file would add, by the file's row.
        var added: [UUID: AgentStatement] = [:]
    }

    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var found: [Found] = []
    @State private var problems: [String] = []

    var body: some View {
        // Worked out on a copy.
        let preview = adding(to: tax.book)
        let count = preview.added.count
        Form {
            Section {
                Button("Choose Statements", systemImage: "doc.badge.plus") { choosing = true }
            } footer: {
                Text("One or more PDFs headed “Remittance Advice” or “Management Statement”, or a CSV of property, gross rent, fee, deductions, net and date. Files are read on this device only.")
            }
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.brandPink) }
                }
            }
            ForEach($found) { $item in
                let statement = item.statement
                let there = tax.book.has(statement, propertyID: item.propertyID)
                Section {
                    Picker("Property", selection: $item.propertyID) {
                        ForEach(tax.book.properties) { Text($0.name).tag($0.id) }
                    }
                    LabeledContent("Rent before deductions", value: TaxMoney.format(statement.grossRent))
                    LabeledContent("Agent fees", value: TaxMoney.format(statement.fees))
                    if statement.repairs != 0 { LabeledContent("Repairs", value: TaxMoney.format(statement.repairs)) }
                    if statement.otherExpense != 0 { LabeledContent("Other costs", value: TaxMoney.format(statement.otherExpense)) }
                    LabeledContent("Paid to you", value: TaxMoney.format(statement.paidToYou))
                    ForEach(statement.warnings, id: \.self) {
                        Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                    }
                    if statement.isChecked {
                        Label("Matches the amount the statement says was paid.", systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout)
                    }
                    if there {
                        Text("Already entered: it will be skipped.").foregroundStyle(.secondary)
                    } else {
                        if let same = tax.book.lookalike(of: statement, propertyID: item.propertyID, in: store.transactions) {
                            Label("Looks like the statement of \(PropertyLedger.day(same.date)) already entered. Importing it would count the rent twice.", systemImage: "doc.on.doc")
                                .foregroundStyle(.orange).font(.callout)
                        }
                        Toggle("Import this statement", isOn: $item.include)
                        if item.include {
                            if let added = preview.added[item.id] {
                                link(added)
                            } else {
                                Text("The same as another file chosen here: it will be added once.").foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("\(PropertyLedger.day(statement.date)) · \(item.fileName)")
                }
            }
            if !found.isEmpty {
                Section {
                    Button("Import \(count) Statement\(count == 1 ? "" : "s")") {
                        tax.change { $0 = adding(to: $0).book }
                        dismiss()
                    }
                    .disabled(count == 0)
                } footer: {
                    Text("You can change any figure or bank payment afterwards in Pay and Statements.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Agent Statements")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf, .commaSeparatedText, .tabSeparatedText, .plainText],
                      allowsMultipleSelection: true) { load($0) }
    }

    @ViewBuilder private func link(_ added: AgentStatement) -> some View {
        if let payment = added.bankFingerprint.flatMap({ id in store.transactions.first { $0.fingerprint == id } }) {
            Label("Links to \(payment.amount.money) from \(payment.merchant) on \(PropertyLedger.day(payment.date)), so the rent isn't counted twice.", systemImage: "link")
                .font(.callout)
        } else {
            Label("No bank payment of this amount found near this date. Import that bank statement first, or link it later.", systemImage: "link.badge.plus")
                .foregroundStyle(.orange)
                .font(.callout)
        }
    }

    private func adding(to book: PropertyBook) -> Preview {
        var result = Preview(book: book)
        // All together, oldest first, so two statements never claim the same bank payment.
        for item in found.filter(\.include).sorted(by: { $0.statement.date < $1.statement.date }) {
            if result.book.add([item.statement], propertyID: item.propertyID, payments: store.transactions) == 1 {
                result.added[item.id] = result.book.statements.last
            }
        }
        return result
    }

    private func load(_ result: Result<[URL], Error>) {
        problems = []
        found = []
        guard let first = tax.book.properties.first else {
            problems = ["Add a property first, in Properties and Rules."]
            return
        }
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { problems = [error.localizedDescription] }
            return
        }
        for url in urls {
            let name = url.lastPathComponent
            do {
                let data = try UploadFile.data(url)
                let statements = url.pathExtension.lowercased() == "pdf"
                    ? [try LettingStatementReader.read(texts: UploadFile.pdfTexts(data))]
                    : try LettingStatementReader.read(csv: String(decoding: data, as: UTF8.self))
                for statement in statements {
                    let named = tax.book.properties.first { property in
                        statement.propertyName.map { property.name.caseInsensitiveCompare($0) == .orderedSame } ?? false
                    }
                    let property = (named ?? first).id
                    let again = tax.book.lookalike(of: statement, propertyID: property, in: store.transactions) != nil
                    found.append(Found(fileName: name, statement: statement, propertyID: property,
                                       include: !statement.needsAttention && !again))
                }
            } catch let error as LettingStatementError {
                problems.append("\(name): \(error.explanation)")
            } catch {
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        found.sort { $0.statement.date < $1.statement.date }
    }
}

/// Choose payslips; the latest one in each tax year sets that year's pay and tax.
struct PayslipImportView: View {
    private struct Year: Identifiable {
        var id: String { year.description }
        let year: TaxYear
        let slip: Payslip
        let fileName: String
        var pay: String
        var deducted: String
        /// Overwrite figures typed in by hand.
        var replaceTyped = false
    }

    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var tax: TaxStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var years: [Year] = []
    @State private var problems: [String] = []
    @State private var person = Person.me
    @State private var employer = ""
    /// The employer name filled in for you, which may be filled in again.
    @State private var suggested = ""

    var body: some View {
        let name = employer.trimmingCharacters(in: .whitespaces)
        let ready = years.filter { canSave($0, employer: name) }
        Form {
            Section {
                Button("Choose Payslips", systemImage: "doc.badge.plus") { choosing = true }
            } footer: {
                Text("PDF payslips that show figures to date, as many umbrella companies' do. Choose several and the latest in each tax year is used. Files are read on this device only.")
            }
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.brandPink) }
                }
            }
            if !years.isEmpty {
                Section {
                    Picker("Whose", selection: $person) {
                        ForEach(store.taxPeople, id: \.person) { Text($0.name).tag($0.person) }
                    }
                    TextField("Employer", text: $employer, prompt: Text("Employer or umbrella company"))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("Employer")
                } footer: {
                    Text("Use the same name each time, so a later payslip updates the same entry.")
                }
            }
            ForEach($years) { $item in
                let current = name.isEmpty ? nil : tax.book.pay(for: person, year: item.year, employer: name)
                let others = tax.book.pay.filter { $0.person == person && $0.taxYear == item.year.description && $0.id != current?.id }
                Section {
                    TaxAmountField(title: "Taxable pay to date", text: $item.pay)
                    TaxAmountField(title: "Tax deducted to date", text: $item.deducted)
                    // Only while the figures are still the ones read.
                    if item.slip.isChecked, TaxMoney.parse(item.pay) == item.slip.taxablePayToDate,
                       TaxMoney.parse(item.deducted) == item.slip.taxToDate {
                        Label("The payslip's figures agree with each other. Still compare these two.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green).font(.callout)
                    }
                    ForEach(item.slip.warnings, id: \.self) {
                        Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                    }
                    if let current {
                        if current.enteredBy != .me {
                            Text("Your partner typed this entry in, so only they can change it.").foregroundStyle(.orange)
                        } else if let later = current.payslipDate, later > item.slip.payDate {
                            Text("A later payslip (\(PropertyLedger.day(later))) is already recorded: nothing to change.").foregroundStyle(.secondary)
                        } else {
                            Text("Replaces \(TaxMoney.format(current.taxablePay)) pay and \(TaxMoney.format(current.taxDeducted)) tax.").foregroundStyle(.secondary)
                            if current.payslipDate == nil {
                                Text("Those were typed in, perhaps from a P60, which covers the whole year.").foregroundStyle(.orange)
                                Toggle("Replace the figures typed in", isOn: $item.replaceTyped)
                            }
                            if current.isShared { Text("This entry is shown to your partner, and stays shown.").foregroundStyle(.secondary) }
                        }
                    }
                    if !others.isEmpty {
                        Label("\(item.year.description) also has pay from \(others.map(\.employer).joined(separator: ", ")). Both are counted: check they aren't the same job.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                } header: {
                    Text("\(item.year.description) · paid \(PropertyLedger.day(item.slip.payDate)) · \(item.fileName)")
                }
            }
            if !years.isEmpty {
                Section {
                    Button("Save Pay") {
                        tax.change { book in
                            for item in ready {
                                book.record(payslipDated: item.slip.payDate, taxablePay: TaxMoney.parse(item.pay)!,
                                            taxDeducted: TaxMoney.parse(item.deducted)!, person: person, employer: name,
                                            replacingTyped: item.replaceTyped)
                            }
                        }
                        dismiss()
                    }
                    .disabled(ready.isEmpty)
                } footer: {
                    Text("A new entry is private unless you choose to show it to your partner. A pension you pay yourself isn't read: add it to the entry if you have one.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Payslips")
        .onChange(of: person) { suggestEmployer() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { load($0) }
    }

    private func canSave(_ item: Year, employer: String) -> Bool {
        guard !employer.isEmpty, TaxMoney.parse(item.pay) != nil, TaxMoney.parse(item.deducted) != nil else { return false }
        var copy = tax.book
        return copy.record(payslipDated: item.slip.payDate, taxablePay: 0, taxDeducted: 0, person: person, employer: employer,
                           replacingTyped: item.replaceTyped)
    }

    /// The employer already entered for these years, when there is just one.
    private func suggestEmployer() {
        let covered = Set(years.map(\.id))
        let names = Set(tax.book.pay.filter { $0.person == person && covered.contains($0.taxYear) }.map(\.employer))
        // A name you typed is left alone.
        guard employer.isEmpty || employer == suggested else { return }
        suggested = names.count == 1 ? names.first! : ""
        employer = suggested
    }

    private func load(_ result: Result<[URL], Error>) {
        problems = []
        years = []
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { problems = [error.localizedDescription] }
            return
        }
        var latest: [TaxYear: (slip: Payslip, file: String)] = [:]
        for url in urls {
            let name = url.lastPathComponent
            do {
                let slip = try PayslipReader.read(texts: UploadFile.pdfTexts(UploadFile.data(url)))
                guard let year = TaxYear.containing(slip.payDate) else {
                    problems.append("\(name): paid \(PropertyLedger.day(slip.payDate)), a tax year the app doesn't cover.")
                    continue
                }
                if latest[year].map({ slip.payDate > $0.slip.payDate }) ?? true { latest[year] = (slip, name) }
            } catch let error as PayslipError {
                problems.append("\(name): \(error.explanation)")
            } catch {
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        years = latest.sorted { $0.key.startYear < $1.key.startYear }.map { year, entry in
            Year(year: year, slip: entry.slip, fileName: entry.file,
                 pay: entry.slip.taxablePayToDate.map { "\($0)" } ?? "", deducted: entry.slip.taxToDate.map { "\($0)" } ?? "")
        }
        suggestEmployer()
        // A file that couldn't be read might be the latest: say so beside the figures.
        if !problems.isEmpty && !years.isEmpty { problems.append("Check that none of the files above is later than the one used.") }
    }
}
