import BudgetCore
import SwiftUI

/// Everything waiting for a decision: scanned receipts to approve and payments without a category.
/// iPhone: a list that opens each item. Mac: the list beside the selected item.
struct InboxView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var selection: BankTransaction.ID?

    var body: some View {
        VStack(spacing: 0) {
            SharedDocumentsBanner()
            PendingReceiptsBanner()
            inboxContent
        }
        .appBackground()
        .navigationTitle(AppSection.inbox.macTitle)
        .safeAreaInset(edge: .bottom) { CategorisingBanner().padding(.bottom, 8) }
        .toolbar {
            if store.uncategorisedCount > 0 {
                ToolbarItem(placement: .primaryAction) {
                    Button("Categorise with AI", systemImage: "wand.and.stars") {
                        Task { await store.categoriseNow() }
                    }
                    .disabled(store.isCategorising)
                    .help("Ask Apple Intelligence on this device to suggest categories")
                }
            }
        }
    }

    @ViewBuilder private var inboxContent: some View {
        Group {
            if store.needsReview.isEmpty {
                ContentUnavailableView(
                    "All caught up",
                    systemImage: "checkmark.seal",
                    description: Text("Scanned receipts and new payments that need a category show up here.")
                )
            } else {
                content
            }
        }
    }

    #if os(iOS)
    private var content: some View {
        List(store.needsReview) { transaction in
            NavigationLink { InboxItemView(transaction: transaction) } label: { InboxRow(transaction: transaction) }
        }
        .scrollContentBackground(.hidden)
    }
    #else
    private var content: some View {
        HStack(spacing: 0) {
            List(store.needsReview, selection: $selection) { transaction in
                InboxRow(transaction: transaction).tag(transaction.id)
            }
            .frame(width: 300)
            Divider()
            if let transaction = store.needsReview.first(where: { $0.id == selection }) {
                InboxItemView(transaction: transaction)
                    .id(transaction.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Choose an item", systemImage: "tray", description: Text("Pick a receipt or payment on the left."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = store.needsReview.first?.id } }
    }
    #endif
}

struct InboxRow: View {
    let transaction: BankTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(transaction.merchant).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(transaction.amount.money).font(.body.weight(.semibold)).monospacedDigit()
            }
            HStack(spacing: 4) {
                if let draft = transaction.pendingSplitDraft {
                    Text("Receipt matched · \(draft.receipt.items.count) items")
                } else {
                    Text("Needs a category").foregroundStyle(Color.brandAmber)
                }
                Text("· \(transaction.date.formatted(.dateTime.day().month(.abbreviated)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Opens the right screen for an inbox item: the receipt check for a scanned receipt,
/// otherwise the transaction editor to pick a category.
struct InboxItemView: View {
    let transaction: BankTransaction

    var body: some View {
        if transaction.pendingSplitDraft != nil {
            ReceiptView(transaction: transaction)
        } else {
            TransactionEditor(transaction: transaction)
        }
    }
}
