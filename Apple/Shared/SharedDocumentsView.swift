import BudgetCore
import SwiftUI

/// Every file shared or opened with the app, and what became of it.
struct SharedDocumentsView: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(store.sharedDocuments) { document in
                    NavigationLink { SharedDocumentDetail(document: document) } label: { SharedDocumentRow(document: document) }
                }
            } footer: {
                Text("Statements are imported straight away. Receipts wait for their payment. If the app guessed wrong, open the file to fix it.")
            }
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .overlay {
            if store.sharedDocuments.isEmpty {
                ContentUnavailableView("Nothing shared yet", systemImage: "square.and.arrow.down",
                                       description: Text("Share a statement or receipt to Duo Budget from any app."))
            }
        }
        .navigationTitle("Shared files")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}

struct SharedDocumentRow: View {
    let document: SharedDocument

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: symbol, tint: document.needsAttention ? .brandPink : .brandPlum)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.fileName).font(.body.weight(.semibold)).lineLimit(1)
                Text(document.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(document.receivedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch document.outcome {
        case .statement(_, _, let difference): difference == nil ? "doc.text" : "exclamationmark.triangle"
        case .statementReady: "doc.badge.clock"
        case .receipt: "receipt"
        case .failed: "xmark.octagon"
        }
    }
}

struct SharedDocumentDetail: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let document: SharedDocument
    @State private var confirmingDelete = false

    private var current: SharedDocument { store.sharedDocuments.first { $0.id == document.id } ?? document }

    var body: some View {
        List {
            Section {
                SharedDocumentRow(document: current)
            }
            switch current.outcome {
            case .statement:
                Section {
                    NavigationLink("See payments in Activity") { TransactionsView() }
                } footer: {
                    Text("Deleting this entry keeps the imported payments.")
                }
            case .statementReady:
                Section {
                    if let name = current.storedFile {
                        NavigationLink("Review and Import") {
                            ImportStatementView(preloadURL: store.sharedFilesFolder.appendingPathComponent(name), sharedDocument: current)
                        }
                    } else {
                        Text("The copy has expired. Share the statement again.").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Nothing is imported until you've checked the preview.")
                }
            case .receipt(let id):
                if let receipt = store.pendingReceipts.first(where: { $0.id == id }) {
                    Section {
                        NavigationLink("Open the waiting receipt") { PendingReceiptDetail(receipt: receipt) }
                        Button("This is a statement: import it instead") {
                            SharedReceiptReader.importAsStatement(receipt, store: store)
                        }
                    }
                } else {
                    Section { Text("Matched to a payment. Check it in the Inbox.").foregroundStyle(.secondary) }
                }
            case .failed:
                Section {
                    NavigationLink("Import a statement by hand") { ImportStatementView() }
                } footer: {
                    Text("For a statement, your bank's CSV or OFX download always works.")
                }
            }
            Section {
                Button("Delete", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(current.fileName)
        .alert("Remove \(current.fileName) from Shared files?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.deleteSharedDocument(current)
                dismiss()
            }
        }
    }
}

/// Inbox banner: shared files, highlighting any that need a look.
struct SharedDocumentsBanner: View {
    @EnvironmentObject var store: BudgetStore
    @State private var showing = false

    var body: some View {
        if !store.sharedDocuments.isEmpty {
            let attention = store.sharedDocuments.filter(\.needsAttention).count
            Button { showing = true } label: {
                HStack(spacing: 12) {
                    IconBadge(systemImage: attention > 0 ? "exclamationmark.triangle" : "tray.and.arrow.down",
                              tint: attention > 0 ? .brandPink : .brandPlum, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shared files").font(.subheadline.weight(.semibold))
                        Text(attention > 0 ? "\(attention) need\(attention == 1 ? "s" : "") a look" : "\(store.sharedDocuments.count) received")
                            .font(.caption)
                            .foregroundStyle(attention > 0 ? Color.brandPink : .secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .card(padding: 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 8)
            .sheet(isPresented: $showing) {
                NavigationStack { SharedDocumentsView() }
                    #if os(macOS)
                    .frame(minWidth: 480, minHeight: 420)
                    #endif
            }
        }
    }
}
