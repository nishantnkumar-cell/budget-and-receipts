import SwiftUI

/// Shown once, on a first launch with no data: currency, names, and the first statement.
/// Everything here can be changed later in Settings, so the person can also just start.
struct WelcomeView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var couple: Binding<CoupleSettings> {
        Binding(get: { store.couple }, set: { store.updateCouple($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to Duo Budget").font(.title2.bold())
                        Text("Your budget and receipts, for you or for the two of you. Everything stays on your devices and in end-to-end encrypted iCloud.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section("Money") {
                    Picker("Currency", selection: $settings.currencyCode) {
                        ForEach(AppSettings.supportedCurrencies, id: \.self) { code in
                            Text("\(code) – \(Locale.current.localizedString(forCurrencyCode: code) ?? code)").tag(code)
                        }
                    }
                }
                Section {
                    TextField("Your name", text: Binding(get: { store.couple.ownerName ?? "" }, set: { couple.wrappedValue.ownerName = $0 }))
                    TextField("Partner's name", text: couple.partnerName, prompt: Text("Leave empty if it's just you"))
                } header: {
                    Text("Who's budgeting")
                } footer: {
                    Text("To share with your partner, invite them later in Settings › Couple.")
                }
                Section {
                    NavigationLink {
                        ImportStatementView()
                    } label: {
                        Label("Import a bank statement", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("CSV, OFX, QFX, QIF or PDF from your bank's website. You can also share statements and receipts to Duo Budget from other apps.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Get started")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }
}

extension WelcomeView {
    static let shownKey = "welcomeShown"

    /// Only for a brand-new install: not after an update, and not for a partner who joined a household.
    @MainActor
    static func shouldShow(store: BudgetStore) -> Bool {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return false }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        #if DEBUG
        if SampleData.isOn { return false }
        #endif
        guard !store.isWaitingForFiles, store.householdRole != .member else { return false }
        guard store.transactions.isEmpty else {
            // Someone who already has data has set up the app before.
            UserDefaults.standard.set(true, forKey: shownKey)
            return false
        }
        return true
    }
}
