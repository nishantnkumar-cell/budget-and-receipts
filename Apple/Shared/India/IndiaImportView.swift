import SwiftUI
import TaxCore
import UniformTypeIdentifiers

/// Choose a rupee statement, check what it will add, then import it into one account.
struct IndiaImportView: View {
    @EnvironmentObject var india: IndiaStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var fileName = ""
    @State private var statement: IndiaStatement?
    @State private var accountID: String?
    @State private var error: String?
    @State private var adding: IndiaAccount?

    var body: some View {
        Form {
            Section {
                Button { choosing = true } label: {
                    Label(fileName.isEmpty ? "Choose statement file" : fileName, systemImage: "doc.badge.plus")
                }
            } footer: {
                Text("An ICICI or SBI account statement saved as CSV, or SBI's tab-separated download. For an Excel file, open it in Numbers or Excel and export it as CSV first. The file is read on this device only.")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.brandPink) }
            }
            if let statement {
                preview(statement)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import Rupee Statement")
        // Any file may be offered: some banks name a text file ".xls".
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data]) { load($0) }
        .sheet(item: $adding) { account in
            IndiaAccountEditor(account: account, isNew: true) { accountID = $0.id }
        }
    }

    @ViewBuilder private func preview(_ statement: IndiaStatement) -> some View {
        Section {
            Picker("Account", selection: $accountID) {
                Text("Choose").tag(String?.none)
                ForEach(india.book.accounts) { Text($0.title).tag(String?.some($0.id)) }
            }
            Button("Add Account", systemImage: "plus") {
                adding = IndiaAccount(bank: .icici, kind: .nro, lastFour: statement.lastFour ?? "")
            }
        } footer: {
            if let ending = statement.lastFour { Text("The file is for an account ending \(ending).") }
        }
        if let accountID, let account = india.book.account(accountID) {
            let result = statement.entries(for: accountID, existing: india.book.entries)
            Section("Preview") {
                if let ending = statement.lastFour, !account.lastFour.isEmpty, ending != account.lastFour {
                    warning("The file is for an account ending \(ending), not \(account.lastFour). Check you chose the right one.")
                }
                if let difference = statement.balanceDifference {
                    warning("The payments don't add up to the change in the file's balance (\(IndiaMoney.format(difference)) apart). A line may be missing; check the file.")
                }
                LabeledContent("New lines", value: "\(result.new.count)")
                LabeledContent("Already imported, skipped", value: "\(result.alreadyThere)")
                LabeledContent("Interest found", value: IndiaMoney.format(result.new.filter { $0.kind == .interest }.reduce(0) { $0 + $1.amount }))
                LabeledContent("Tax deducted found", value: IndiaMoney.format(-result.new.filter { $0.kind == .taxDeducted }.reduce(0) { $0 + $1.amount }))
                ForEach(result.new.prefix(5)) { line in
                    HStack {
                        Text(PropertyLedger.day(line.date)).foregroundStyle(.secondary)
                        Text(line.narration).lineLimit(1)
                        Spacer()
                        Text(IndiaMoney.format(line.amount)).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            Section {
                Button("Import \(result.new.count) Lines") {
                    india.change { book in
                        book.entries += statement.entries(for: accountID, existing: book.entries).new
                    }
                    dismiss()
                }
                .disabled(result.new.isEmpty)
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(Color.brandPink).font(.callout)
    }

    private func load(_ result: Result<URL, Error>) {
        error = nil
        statement = nil
        accountID = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            fileName = url.lastPathComponent
            let read = try IndiaStatement.read(Data(contentsOf: url))
            statement = read
            let matching = india.book.accounts.filter { !$0.lastFour.isEmpty && $0.lastFour == read.lastFour }
            if matching.count == 1 { accountID = matching[0].id }
        } catch let failure as IndiaStatementError {
            error = failure.explanation
        } catch {
            self.error = error.localizedDescription
        }
    }
}
