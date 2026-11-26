import BudgetCore
import SwiftUI
import TaxCore

extension BudgetStore {
    /// The figures for one tax year from the payments here, with anything that makes them
    /// doubtful on this device.
    func propertyLedger(_ tax: TaxStore) -> PropertyLedger {
        var ledger = PropertyLedger.build(transactions: transactions, book: tax.book, year: tax.year)
        if AppSettings.currency != "GBP" {
            ledger.issues.append(.init(message: "Tax figures need your budget in pounds. It's set to \(AppSettings.currency) in Settings.", blocksFiling: true))
        }
        if tax.unreadableCount > 0 {
            ledger.issues.append(.init(message: "\(tax.unreadableCount) tax items can't be read, probably saved by a newer version. Update the app on this device.", blocksFiling: true))
        }
        if householdRole != .solo {
            ledger.issues.append(.init(message: "Payments your partner keeps private aren't included on this device.", blocksFiling: false))
        }
        return ledger
    }

    var taxPeople: [(person: Person, name: String)] {
        let partner = couple.partnerName.trimmingCharacters(in: .whitespaces)
        return [(.me, "You"), (.partner, hasPartner && !partner.isEmpty ? partner : "Spouse")]
    }
}

/// A sheet with Cancel and Save.
struct TaxSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let canSave: Bool
    let save: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            Form { content }
                .formStyle(.grouped)
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
        }
        // Tax dates are dates in London.
        .environment(\.timeZone, TaxYear.calendar.timeZone)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }
}

/// Pounds as typed. Empty means nothing.
struct TaxAmountField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text("0.00"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(text.isEmpty || TaxMoney.parse(text) != nil ? Color.primary : Color.red)
                .accessibilityIdentifier(title)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
    }

    static func value(_ text: String) -> Decimal? { text.isEmpty ? 0 : TaxMoney.parse(text) }
    static func text(_ value: Decimal) -> String { value == 0 ? "" : "\(value)" }
}

/// A button that asks before removing something.
struct TaxRemoveButton: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var warning = "This can't be undone here."
    let remove: () -> Void
    @State private var asking = false

    var body: some View {
        Section {
            Button(title, role: .destructive) { asking = true }
                .confirmationDialog(title, isPresented: $asking) {
                    Button(title, role: .destructive) {
                        remove()
                        dismiss()
                    }
                } message: {
                    Text(warning)
                }
        }
    }
}

/// Which tax year the screen shows.
struct TaxYearPicker: View {
    @EnvironmentObject var tax: TaxStore

    var body: some View {
        Picker("Tax year", selection: $tax.year) {
            ForEach(TaxYear.supported, id: \.self) { Text($0.description).tag($0) }
        }
    }
}
