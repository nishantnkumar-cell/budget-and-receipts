import BudgetCore
import SwiftUI

/// Scanned receipts still waiting for their card payment to reach a statement.
struct PendingReceiptsView: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(store.pendingReceipts) { receipt in
                    NavigationLink { PendingReceiptDetail(receipt: receipt) } label: { PendingReceiptRow(receipt: receipt) }
                }
            } footer: {
                Text("Each receipt is matched automatically when you import a statement with one payment of the same total, dated from 2 days before to 7 days after the receipt. You can also pick the payment yourself.")
            }
        }
        .overlay {
            if store.pendingReceipts.isEmpty {
                ContentUnavailableView("No receipts waiting", systemImage: "clock.badge.checkmark")
            }
        }
        .navigationTitle("Waiting for payment")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

struct PendingReceiptRow: View {
    let receipt: PendingReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(receipt.editor.merchant.isEmpty ? "Receipt" : receipt.editor.merchant).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                Text((receipt.editor.receiptTotal ?? receipt.editor.splitTotal).money).font(.body.weight(.semibold)).monospacedDigit()
            }
            Text("\(receipt.editor.items.count) items · \(receipt.purchaseDate.formatted(.dateTime.day().month(.abbreviated)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One waiting receipt: the payments it could be, best first, and a way to remove it.
struct PendingReceiptDetail: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let receipt: PendingReceipt
    @State private var confirmingDelete = false

    private var options: [ReceiptMatch] {
        ReceiptMatcher.candidates(for: receipt.editor, in: store.transactions, today: receipt.scannedAt)
    }

    var body: some View {
        List {
            Section("Receipt") {
                PendingReceiptRow(receipt: receipt)
            }
            Section {
                ForEach(options) { option in
                    Button {
                        store.attachPending(receipt, to: option.transaction)
                        dismiss()
                    } label: {
                        HStack {
                            TransactionRow(transaction: option.transaction)
                            if option.amountMatches {
                                Text("Same total").font(.caption.weight(.bold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .foregroundStyle(Color.brandInk)
                                    .background(Color.brandAmber, in: Capsule())
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if options.isEmpty {
                    Text("No payments to choose from yet. Import a statement.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Is it one of these payments?")
            } footer: {
                Text("Picking one moves the receipt to the Inbox, where you check it and approve.")
            }
            Section {
                Button("This is a statement: import it instead") {
                    SharedReceiptReader.importAsStatement(receipt, store: store)
                    dismiss()
                }
            } footer: {
                Text("For a bank or card statement that was read as a receipt.")
            }
            Section {
                Button("Delete Receipt", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(receipt.editor.merchant.isEmpty ? "Receipt" : receipt.editor.merchant)
        .confirmationDialog("Delete this receipt?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                store.deletePending(receipt)
                dismiss()
            }
        }
    }
}

/// A banner at the top of the Inbox while receipts are waiting for their payment.
struct PendingReceiptsBanner: View {
    @EnvironmentObject var store: BudgetStore
    @State private var showing = false

    var body: some View {
        if !store.pendingReceipts.isEmpty {
            Button { showing = true } label: {
                Label("\(store.pendingReceipts.count) receipt\(store.pendingReceipts.count == 1 ? "" : "s") waiting for a payment", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .padding([.horizontal, .top])
            .sheet(isPresented: $showing) {
                NavigationStack { PendingReceiptsView() }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 420)
                    #endif
            }
        }
    }
}
