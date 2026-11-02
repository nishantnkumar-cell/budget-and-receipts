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
        Form {
            Section("Receipt image") {
                ReceiptImagePreview(imagePath: editor.imagePath)
                HStack {
                    Button("Choose Image…") { choosingImage = true }
                    Spacer()
                    Text("or drop a photo here, or use File › Import from iPhone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let scanMessage {
                    Text(scanMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Editable receipt") {
                TextField("Merchant", text: $editor.merchant)
                DatePicker("Date", selection: Binding(get: { editor.purchaseDate ?? transaction.date }, set: { editor.purchaseDate = $0 }), displayedComponents: .date)
                TextField("Receipt total", value: $editor.receiptTotal, format: .number)
                TextField("Subtotal", value: $editor.subtotal, format: .number)
                TextField("VAT", value: $editor.tax, format: .number)
            }
            Section("Editable items") {
                ForEach($editor.items) { $item in
                    HStack {
                        TextField("Description", text: $item.description)
                        TextField("Amount", value: $item.total, format: .number).frame(width: 100)
                        Picker("Category", selection: $item.category) {
                            ForEach(FinanceCategories.all, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        if store.hasPartner {
                            OwnerPicker(owner: $item.owner).labelsHidden().frame(width: 110)
                        }
                        Button(role: .destructive) {
                            editor.deleteItem(item.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                Button("Add item") { editor.addItem() }
            }
            ReconciliationSection(bankAmount: transaction.amount, splitTotal: editor.splitTotal, balanced: balanced)
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
        .confirmationDialog("Create these splits?", isPresented: $confirm) {
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

    var body: some View {
        if let url = ReceiptImageStore().url(for: imagePath) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                ProgressView()
            }
            .frame(maxHeight: 240)
            .accessibilityLabel("Receipt photo")
        }
    }
}
