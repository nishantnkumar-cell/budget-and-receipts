import BudgetCore
import SwiftUI
import UniformTypeIdentifiers

/// Edit a receipt draft line by line and approve it as splits of a bank transaction.
/// Used on the Mac; the iPhone uses `ReceiptView`, which adds photo and camera input.
struct ApprovalView: View {
    @EnvironmentObject var store: BudgetStore
    let transaction: BankTransaction
    @State private var editor = ReceiptDraftEditor()
    @State private var reviewed = false
    @State private var confirm = false
    @State private var choosingImage = false
    @State private var scanMessage: String?
    private let vision = ReceiptVisionService()

    private var difference: Decimal { abs(transaction.amount) - editor.splitTotal }
    private var balanced: Bool { abs(difference) <= SplitApprovalPolicy().tolerance }

    var body: some View {
        // Items first on the left, the scanned receipt on the right (the approved Mac mock-up).
        HStack(spacing: 0) {
            details
            Divider()
            receiptPanel
                .frame(minWidth: 260, idealWidth: 340, maxWidth: 420)
        }
        .onAppear(perform: loadPendingDraft)
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            guard let url = try? result.get() else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { scan(data, fileExtension: url.pathExtension) }
        }
        .dropDestination(for: Data.self) { items, _ in
            guard let data = items.first else { return false }
            scan(data, fileExtension: "jpg")
            return true
        }
        #if os(macOS)
        // Continuity Camera: File › Import from iPhone takes a photo with the phone.
        .importsItemProviders([.image]) { providers in
            guard let provider = providers.first else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in scan(data, fileExtension: "jpg") }
            }
            return true
        }
        #endif
    }

    /// The scanned receipt, as large as the space allows, with ways to add or replace it.
    private var receiptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Receipt").font(.headline)
            if editor.imagePath.isEmpty {
                ContentUnavailableView("No receipt yet", systemImage: "doc.viewfinder", description: Text("Choose an image, drop a photo here, or use File › Import from iPhone."))
                    .frame(maxHeight: .infinity)
            } else {
                ReceiptImagePreview(imagePath: editor.imagePath, maxHeight: .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button(editor.imagePath.isEmpty ? "Choose Image…" : "Replace Image…") { choosingImage = true }
            if let scanMessage {
                Text(scanMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.secondary)
    }

    private var details: some View {
        Form {
            Section("Editable receipt") {
                DuplicateReceiptBanner(warning: store.possibleDuplicate(of: editor))
                TextField("Merchant", text: $editor.merchant)
                DatePicker("Date", selection: Binding(get: { editor.purchaseDate ?? transaction.date }, set: { editor.purchaseDate = $0 }), displayedComponents: .date)
                TextField("Receipt total", value: $editor.receiptTotal, format: .number)
                TextField("Subtotal", value: $editor.subtotal, format: .number)
                TextField("VAT", value: $editor.tax, format: .number)
            }
            Section {
                ForEach($editor.items) { $item in
                    // Fixed column widths keep every row lined up under the headings.
                    HStack(spacing: 12) {
                        TextField("Description", text: $item.description)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TextField("Amount", value: $item.total, format: .number.precision(.fractionLength(2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 90)
                        Picker("Category", selection: $item.category) {
                            ForEach(FinanceCategories.all, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Button(role: .destructive) {
                            editor.deleteItem(item.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 20)
                    }
                }
                Button("Add item") { editor.addItem() }
            } header: {
                HStack(spacing: 12) {
                    Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Amount").frame(width: 90, alignment: .trailing)
                    Text("Category").frame(width: 170, alignment: .trailing)
                    Color.clear.frame(width: 20)
                }
            }
            ReconciliationSection(bankAmount: transaction.amount, splitTotal: editor.splitTotal, balanced: balanced)
            ReceiptCoverSection(transactionID: transaction.id, shop: editor.merchant.isEmpty ? transaction.merchant : editor.merchant,
                                date: editor.purchaseDate ?? transaction.date, item: editor.items.max { $0.total < $1.total }?.description ?? "",
                                price: editor.items.max { $0.total < $1.total }?.total, imagePath: editor.imagePath)
            Section("Approval") {
                Toggle("I have checked every item and category", isOn: $reviewed)
                Text(store.status).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save Draft Only") { store.saveDraft(editor.makeDraft(reviewed: false), for: transaction) }
                    Spacer()
                    Button("Review and Approve…") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!reviewed || !balanced || editor.items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Create these splits?", isPresented: $confirm) {
            Button("Approve and Create \(editor.items.count) Splits") {
                var draft = editor.makeDraft(reviewed: reviewed)
                draft.approvedAt = Date()
                store.approve(draft, for: transaction)
            }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    /// Saves a copy of the image, reads it with Vision on this device, and fills the draft.
    private func scan(_ data: Data, fileExtension: String) {
        scanMessage = "Reading receipt…"
        Task {
            do {
                let imagePath = try ReceiptImageStore().save(data, fileExtension: fileExtension.isEmpty ? "jpg" : fileExtension)
                var result = try await vision.recognise(data: data)
                store.categoriser.categorise(&result)
                result.imagePath = imagePath
                if result.purchaseDate == nil { result.purchaseDate = transaction.date }
                editor = result
                reviewed = false
                scanMessage = "Read \(result.items.count) items. Check every line before approving."
            } catch {
                scanMessage = "Could not read that image: \(error.localizedDescription)"
            }
        }
    }

    private func loadPendingDraft() {
        guard editor.items.isEmpty, let receipt = transaction.pendingSplitDraft?.receipt else { return }
        editor = ReceiptDraftEditor(
            merchant: receipt.merchant,
            purchaseDate: receipt.purchaseDate,
            subtotal: receipt.subtotal,
            tax: receipt.tax,
            receiptTotal: receipt.total,
            items: receipt.items,
            rawText: receipt.rawText,
            imagePath: receipt.imagePath
        )
    }
}

struct ReconciliationSection: View {
    let bankAmount: Decimal
    let splitTotal: Decimal
    let balanced: Bool

    var body: some View {
        Section("Reconciliation") {
            LabeledContent("Bank amount") { Text(abs(bankAmount), format: .currency(code: AppSettings.currency)) }
            LabeledContent("Split total") { Text(splitTotal, format: .currency(code: AppSettings.currency)) }
            LabeledContent("Difference") { Text(abs(abs(bankAmount) - splitTotal), format: .currency(code: AppSettings.currency)) }
            Label(
                balanced ? "Balanced" : "Adjust items until the difference is zero",
                systemImage: balanced ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
        }
    }
}

/// Shows the saved receipt image, if there is one.
struct ReceiptImagePreview: View {
    let imagePath: String
    var maxHeight: CGFloat = 240

    var body: some View {
        if let url = ReceiptImageStore().url(for: imagePath) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView()
            }
            .frame(maxHeight: maxHeight)
            .accessibilityLabel("Receipt photo")
        }
    }
}
