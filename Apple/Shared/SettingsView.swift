import BudgetCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    @State private var exportingCSV = false
    @State private var exportingPDF = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section("Money") {
                Picker("Currency", selection: $settings.currencyCode) {
                    ForEach(AppSettings.supportedCurrencies, id: \.self) { code in
                        Text("\(code) – \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(code)
                    }
                }
            }
            Section {
                Toggle("Lock with \(AppLock().methodName)", isOn: $settings.appLockEnabled)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Asks for \(AppLock().methodName) when the app opens or comes back from the background.")
            }
            Section {
                Toggle("Payment and renewal reminders", isOn: Binding(get: { settings.remindersEnabled }, set: setReminders))
            } footer: {
                Text("Notifies you 2 days before a payment, 2 weeks before a renewal or fixed price ends, and a week before a cancellation deadline.")
            }
            Section("Export") {
                Button("Export All Transactions (CSV)") { exportingCSV = true }
                Button("Export \(store.selectedMonth.formatted(.dateTime.month(.wide).year())) Report (PDF)") { exportingPDF = true }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(Color.brandPink)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileExporter(isPresented: $exportingCSV, document: ExportDocument(data: Data(CSVExporter.transactions(store.transactions).utf8), type: .commaSeparatedText), contentType: .commaSeparatedText, defaultFilename: "Budget transactions.csv") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportingPDF, document: ExportDocument(data: MonthReportPDF.render(store.monthReport), type: .pdf), contentType: .pdf, defaultFilename: "Budget \(store.selectedMonth.formatted(.dateTime.year().month(.twoDigits))).pdf") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
    }

    private func setReminders(_ on: Bool) {
        Task {
            let allowed = on ? await ReminderScheduler.requestPermission() : true
            settings.remindersEnabled = on && allowed
            await ReminderScheduler.reschedule(subscriptions.contracts, enabled: settings.remindersEnabled)
        }
    }
}

struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .pdf]
    let data: Data
    let type: UTType

    init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A one-page PDF of the month's income, spending and budget lines.
@MainActor
enum MonthReportPDF {
    static func render(_ report: MonthlyBudgetReport) -> Data {
        let renderer = ImageRenderer(content: MonthReportPage(report: report).frame(width: 595, height: 842))
        let data = NSMutableData()
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return data as Data
    }
}

struct MonthReportPage: View {
    let report: MonthlyBudgetReport

    private func money(_ value: Decimal) -> String { value.formatted(.currency(code: AppSettings.currency)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Budget for \(report.month.formatted(.dateTime.month(.wide).year()))").font(.title.bold())
            HStack(spacing: 24) {
                LabeledContent("Income", value: money(report.income))
                LabeledContent("Spending", value: money(report.spending))
                LabeledContent("Net", value: money(report.net))
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Category").bold()
                    Text("Spent").bold()
                    Text("Limit").bold()
                    Text("Left").bold()
                }
                ForEach(report.lines) { line in
                    GridRow {
                        Text(line.category)
                        Text(money(line.spent))
                        Text(line.limit.map(money) ?? "–")
                        Text(line.remaining.map(money) ?? "–")
                            .foregroundStyle(line.isOverBudget ? Color.red : Color.primary)
                    }
                }
            }
            Spacer()
            Text("Made with Budget & Receipts on \(Date().formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .foregroundStyle(.black)
        .background(.white)
    }
}
