import BudgetCore
import SwiftUI
import UniformTypeIdentifiers

/// Choose a bank statement (CSV, OFX or QIF), check what it will add, then import it.
struct ImportStatementView: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false
    @State private var fileName = ""
    @State private var text = ""
    @State private var header: [String] = []
    @State private var mapping: CSVColumnMapping?
    @State private var preview: StatementImportResult?
    @State private var error: String?

    private static let types: [UTType] = [
        .commaSeparatedText,
        UTType(filenameExtension: "ofx") ?? .data,
        UTType(filenameExtension: "qfx") ?? .data,
        UTType(filenameExtension: "qif") ?? .data,
        .plainText
    ]

    private var isCSV: Bool { StatementFormat(fileName: fileName) == .csv }

    var body: some View {
        Form {
            Section {
                Button {
                    choosingFile = true
                } label: {
                    Label(fileName.isEmpty ? "Choose statement file" : fileName, systemImage: "doc.badge.plus")
                }
                Text("CSV, OFX or QIF exported from your bank. The file is read on this device only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isCSV, !header.isEmpty {
                Section("Columns") {
                    columnPicker("Date", \.date)
                    columnPicker("Description", \.description)
                    Picker("Amounts", selection: Binding(get: { mapping?.amount != nil }, set: setSingleAmount)) {
                        Text("One amount column").tag(true)
                        Text("Paid out and paid in").tag(false)
                    }
                    if mapping?.amount != nil {
                        optionalColumnPicker("Amount", \.amount)
                    } else {
                        optionalColumnPicker("Paid out", \.paidOut)
                        optionalColumnPicker("Paid in", \.paidIn)
                    }
                    Picker("Dates like 03/10", selection: Binding(get: { mapping?.dateOrder ?? .dayMonthYear }, set: { mapping?.dateOrder = $0; refresh() })) {
                        Text("3 October (UK)").tag(DateOrder.dayMonthYear)
                        Text("10 March (US)").tag(DateOrder.monthDayYear)
                    }
                    Toggle("Decimal comma (12,50)", isOn: Binding(get: { mapping?.decimalComma ?? false }, set: { mapping?.decimalComma = $0; refresh() }))
                }
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.brandPink) }
            }

            if let preview {
                Section("Preview") {
                    LabeledContent("New transactions", value: "\(preview.newTransactions.count)")
                    LabeledContent("Already imported, skipped", value: "\(preview.duplicates.count)")
                    if !preview.possibleDuplicates.isEmpty {
                        LabeledContent("Check: same day and amount as an existing entry", value: "\(preview.possibleDuplicates.count)")
                    }
                    ForEach(preview.newTransactions.prefix(5)) { transaction in
                        HStack {
                            Text(transaction.date, format: .dateTime.day().month())
                                .foregroundStyle(.secondary)
                            Text(transaction.merchant).lineLimit(1)
                            Spacer()
                            Text(transaction.amount, format: .currency(code: AppSettings.currency)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
                Section {
                    Button("Import \(preview.newTransactions.count) Transactions") {
                        store.commitImport(preview, fileName: fileName)
                        dismiss()
                    }
                    .disabled(preview.newTransactions.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Import Statement")
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: Self.types) { result in
            load(result)
        }
    }

    private func columnPicker(_ title: String, _ keyPath: WritableKeyPath<CSVColumnMapping, Int>) -> some View {
        Picker(title, selection: Binding(get: { mapping?[keyPath: keyPath] ?? 0 }, set: { mapping?[keyPath: keyPath] = $0; refresh() })) {
            ForEach(header.indices, id: \.self) { Text(header[$0]).tag($0) }
        }
    }

    private func optionalColumnPicker(_ title: String, _ keyPath: WritableKeyPath<CSVColumnMapping, Int?>) -> some View {
        Picker(title, selection: Binding(get: { mapping?[keyPath: keyPath] ?? -1 }, set: { mapping?[keyPath: keyPath] = $0 < 0 ? nil : $0; refresh() })) {
            Text("None").tag(-1)
            ForEach(header.indices, id: \.self) { Text(header[$0]).tag($0) }
        }
    }

    private func setSingleAmount(_ single: Bool) {
        guard var current = mapping else { return }
        if single {
            current.amount = current.amount ?? current.paidOut ?? 0
            current.paidOut = nil
            current.paidIn = nil
        } else {
            current.paidOut = current.paidOut ?? current.amount
            current.paidIn = current.paidIn ?? current.amount
            current.amount = nil
        }
        mapping = current
        refresh()
    }

    private func load(_ result: Result<URL, Error>) {
        error = nil
        preview = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            fileName = url.lastPathComponent
            text = String(decoding: data, as: UTF8.self)
            header = isCSV ? CSVReader.firstRecord(text) : []
            mapping = isCSV ? (CSVColumnMapping.guess(header: header) ?? CSVColumnMapping(date: 0, description: min(1, max(header.count - 1, 0)), amount: max(header.count - 1, 0))) : nil
            refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refresh() {
        guard !text.isEmpty else { return }
        do {
            preview = try store.previewImport(text: text, fileName: fileName, mapping: mapping)
            error = nil
        } catch let failure as StatementImportError {
            preview = nil
            error = failure.explanation
        } catch {
            preview = nil
            self.error = error.localizedDescription
        }
    }
}

extension StatementImportError {
    var explanation: String {
        switch self {
        case .empty: "No transactions were found in this file."
        case .missingColumn(let name): "Choose the column for \(name)."
        case .badDate(let line, let value): "Line \(line): \"\(value)\" is not a date. Check the date column and date style."
        case .badAmount(let line, let value): "Line \(line): \"\(value)\" is not an amount. Check the amount columns."
        }
    }
}
