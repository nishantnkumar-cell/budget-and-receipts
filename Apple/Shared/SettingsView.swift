import BudgetCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    @EnvironmentObject var syncStatus: SyncStatus
    @State private var exportingCSV = false
    @State private var exportingPDF = false
    @State private var exportError: String?

    var body: some View {
        Form {
            Section {
                Picker("Budget month starts on", selection: $settings.monthStartDay) {
                    Text("The 1st").tag(1)
                    ForEach(2...28, id: \.self) { Text("The \($0.formatted(.number))").tag($0) }
                }
            } header: {
                Text("Payday")
            } footer: {
                Text("Choose your payday to budget from one pay to the next instead of by calendar month.")
            }
            Section("Money") {
                Picker("Currency", selection: $settings.currencyCode) {
                    ForEach(AppSettings.supportedCurrencies, id: \.self) { code in
                        Text("\(code) – \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(code)
                    }
                }
            }
            Section {
                Toggle("Sync with iCloud", isOn: $settings.iCloudSyncEnabled)
                    .disabled(CloudSync.containerID == nil)
                if settings.iCloudSyncEnabled, CloudSync.containerID != nil {
                    LabeledContent("Status", value: syncStatus.text)
                    HeldDeletionsRow()
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text(CloudSync.containerID == nil
                     ? "iCloud sync isn't available in this version of the app yet."
                     : "Keeps your budget, receipts and contracts the same on your iPhone and Mac, through your own iCloud. Items marked Private stay private when you later share your household with a partner.")
            }
            HouseholdSharingSection()
            CoupleSettingsSection()
            AccountsSettingsSection()
            Section {
                Toggle("Lock with \(AppLock().methodName)", isOn: $settings.appLockEnabled)
            } header: {
                Text("Privacy")
            } footer: {
                Text(AppLock().methodName == "Passcode" && !AppLock().canAuthenticate
                     ? "This device has no passcode, so the lock can't work. Set one in System Settings."
                     : "Asks for \(AppLock().methodName) when the app opens, comes back after being away, or (on the Mac) after sleep or the screen locks. Hides your figures in the app switcher and keeps details off the lock screen.")
            }
            Section {
                Toggle("Suggest categories with Apple Intelligence", isOn: $settings.aiCategoriesEnabled)
                Toggle("Look up unknown shops online", isOn: $settings.onlineCategoriesEnabled)
            } header: {
                Text("Categories")
            } footer: {
                Text("For shops the app doesn't know yet. Apple Intelligence works on this device and sends nothing. The online lookup asks Apple Maps what kind of business it is, sending only the shop's name and town, never amounts or dates. Your own category choices always win.")
            }
            Section {
                Toggle("Smart receipt reading", isOn: $settings.smartReceiptsEnabled)
            } header: {
                Text("Receipts")
            } footer: {
                Text(ReceiptAIService.unavailableReason ?? "Uses Apple Intelligence on this device when a receipt's items don't add up. Nothing leaves the device, and you still check every item.")
            }
            Section {
                Toggle("Payment and renewal reminders", isOn: Binding(get: { settings.remindersEnabled }, set: setReminders))
            } footer: {
                Text("Notifies you 2 days before a payment, 2 weeks before a renewal or fixed price ends, and a week before a cancellation deadline.")
            }
            Section {
                NavigationLink { EraseAllDataView() } label: {
                    Label("Erase All Data…", systemImage: "trash").foregroundStyle(.red)
                }
            } header: {
                Text("Start again")
            } footer: {
                Text("Asks for Face ID or your passcode, then for the word ERASE, before deleting anything.")
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
        .fileExporter(isPresented: $exportingCSV, document: ExportDocument(data: Data(CSVExporter.transactions(store.transactions, ledger: store.hasPartner ? store.ledger : nil).utf8), type: .commaSeparatedText), contentType: .commaSeparatedText, defaultFilename: "Budget transactions.csv") { result in
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
            Text("Made with Duo Budget on \(Date().formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .foregroundStyle(.black)
        .background(.white)
    }
}
