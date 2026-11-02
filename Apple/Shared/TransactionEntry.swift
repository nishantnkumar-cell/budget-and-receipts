import BudgetCore
import SwiftUI

/// Amount entry that keeps the sign right: choose money out or in, then type the amount
/// as a positive number. Stored amounts stay signed (negative for money out).
struct SignedAmountField: View {
    @Binding var amount: Decimal

    private var isMoneyIn: Binding<Bool> {
        Binding(get: { amount > 0 }, set: { moneyIn in
            let size = abs(amount)
            amount = moneyIn ? size : -size
        })
    }

    var body: some View {
        Picker("Type", selection: isMoneyIn) {
            Text("Money out").tag(false)
            Text("Money in").tag(true)
        }
        .pickerStyle(.segmented)
        TextField("Amount", value: Binding(
            get: { abs(amount) },
            set: { amount = isMoneyIn.wrappedValue ? abs($0) : -abs($0) }
        ), format: .number.precision(.fractionLength(2)))
        .decimalKeyboard()
    }
}

/// A new manual transaction. Nothing is added until Save, so a stray tap adds nothing.
struct NewTransactionView: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State private var transaction = BankTransaction(
        date: Date(), merchant: "", description: "Manual entry", amount: 0, category: "Uncategorised",
        fingerprint: "manual:\(UUID().uuidString)"
    )

    var body: some View {
        Form {
            TextField("Merchant or payee", text: $transaction.merchant)
            SignedAmountField(amount: $transaction.amount)
            DatePicker("Date", selection: $transaction.date, displayedComponents: .date)
            Picker("Category", selection: $transaction.category) {
                ForEach(FinanceCategories.all, id: \.self) { Text($0).tag($0) }
            }
            if !store.accounts.isEmpty {
                AccountPicker(selection: $transaction.accountID)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Transaction")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    store.add(transaction)
                    dismiss()
                }
                .disabled(transaction.merchant.trimmingCharacters(in: .whitespaces).isEmpty || transaction.amount == 0)
            }
        }
    }
}

/// Delete with a confirmation. Manual entries go for good; an imported line comes back if
/// the same statement is imported again, so the dialog says so.
struct DeleteTransactionButton: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let transaction: BankTransaction
    @State private var confirming = false

    var body: some View {
        Button("Delete Transaction", role: .destructive) { confirming = true }
            .alert("Delete \(transaction.merchant)?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    store.delete(transaction)
                    dismiss()
                }
            } message: {
                Text(transaction.isManual
                     ? "This removes it from every device that syncs with iCloud."
                     : "It came from a statement. It's removed from every device, and comes back only if you import that statement again.")
            }
    }
}

extension BankTransaction {
    /// Added by hand rather than imported from a statement.
    var isManual: Bool { fingerprint.hasPrefix("manual:") || description == "Manual entry" }
}

/// A strip that shows while categories are being found, then what was done, for a few seconds.
struct CategorisingBanner: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        Group {
            if store.isCategorising {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding categories for new shops…")
                }
            } else if let result = store.categorisingResult {
                Label(result, systemImage: "wand.and.stars")
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        store.categorisingResult = nil
                    }
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .opacity(store.isCategorising || store.categorisingResult != nil ? 1 : 0)
        .animation(.default, value: store.isCategorising)
    }
}
