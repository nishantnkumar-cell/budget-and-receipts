import BudgetCore
import SwiftUI

#if os(iOS)
import PhotosUI
import UIKit

/// iPhone receipt flow: pick or photograph a receipt, OCR it on the device, correct it, approve.
/// Does everything the Mac's `ApprovalView` does (a receipt that is waiting or matched opens
/// with its items, date, subtotal and VAT, and approving asks first), laid out for the phone.
struct ReceiptView: View {
    @EnvironmentObject var store: BudgetStore
    let transaction: BankTransaction
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var editor = ReceiptDraftEditor()
    @State private var reviewed = false
    @State private var confirm = false
    @State private var message = "Choose or photograph a receipt, then check every item."
    private let vision = ReceiptVisionService()

    private var balanced: Bool { abs(abs(transaction.amount) - editor.splitTotal) <= SplitApprovalPolicy().tolerance }

    var body: some View {
        Form {
            Section {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                        .accessibilityLabel("Receipt photo")
                } else if !editor.imagePath.isEmpty {
                    ReceiptImagePreview(imagePath: editor.imagePath)
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(editor.imagePath.isEmpty && image == nil ? "Choose Receipt Photo" : "Replace Receipt Photo", systemImage: "photo")
                }
                .onChange(of: pickerItem) { _, newItem in load(newItem) }
                NavigationLink {
                    CameraCaptureView(image: $image, onSaved: { scan($0) })
                } label: {
                    Label("Use Camera", systemImage: "camera")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            }
            Section("Receipt") {
                DuplicateReceiptBanner(warning: store.possibleDuplicate(of: editor))
                TextField("Merchant", text: $editor.merchant)
                DatePicker("Date", selection: Binding(get: { editor.purchaseDate ?? transaction.date }, set: { editor.purchaseDate = $0 }), displayedComponents: .date)
                LabeledContent("Receipt total") {
                    TextField("Total", value: $editor.receiptTotal, format: .number).decimalKeyboard().multilineTextAlignment(.trailing)
                }
                LabeledContent("Subtotal") {
                    TextField("Subtotal", value: $editor.subtotal, format: .number).decimalKeyboard().multilineTextAlignment(.trailing)
                }
                LabeledContent("VAT") {
                    TextField("VAT", value: $editor.tax, format: .number).decimalKeyboard().multilineTextAlignment(.trailing)
                }
            }
            Section("Items") {
                ForEach($editor.items) { $line in
                    VStack {
                        TextField("Description", text: $line.description)
                        HStack {
                            TextField("Amount", value: $line.total, format: .number.precision(.fractionLength(2)))
                                .decimalKeyboard()
                                .monospacedDigit()
                            Picker("Category", selection: $line.category) {
                                ForEach(FinanceCategories.all, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                }
                .onDelete { editor.items.remove(atOffsets: $0) }
                Button("Add Item", systemImage: "plus") { editor.addItem() }
            }
            ReconciliationSection(bankAmount: transaction.amount, splitTotal: editor.splitTotal, balanced: balanced)
            Section {
                Toggle("I have checked every item and category", isOn: $reviewed)
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Save Draft Only") {
                    store.saveDraft(editor.makeDraft(reviewed: false), for: transaction)
                    message = store.status
                }
                Button("Review and Approve…") { confirm = true }
                    .disabled(!reviewed || !balanced || editor.items.isEmpty)
            }
        }
        .navigationTitle("Receipt")
        .onAppear(perform: loadPendingDraft)
        .confirmationDialog("Create these splits?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Approve and Create \(editor.items.count) Splits") {
                var draft = editor.makeDraft(reviewed: reviewed)
                draft.approvedAt = Date()
                store.approve(draft, for: transaction)
                message = store.status
            }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        Task {
            guard let data = try? await item?.loadTransferable(type: Data.self), let picked = UIImage(data: data) else { return }
            image = picked
            scan(picked, data: data)
        }
    }

    private func scan(_ picked: UIImage, data: Data? = nil) {
        message = "Reading receipt…"
        Task {
            do {
                var result = try await vision.recognise(image: picked)
                store.categoriser.categorise(&result)
                // Keep the receipt so it can be looked at again after approval.
                if let saved = data ?? picked.jpegData(compressionQuality: 0.8) {
                    result.imagePath = (try? ReceiptImageStore().save(saved)) ?? ""
                }
                if result.purchaseDate == nil { result.purchaseDate = transaction.date }
                editor = result
                reviewed = false
                message = "Read \(result.items.count) items. Check every line before approving."
            } catch {
                message = "Could not read that photo: \(error.localizedDescription)"
            }
        }
    }

    /// A receipt that was saved as a draft, or is waiting and was matched, opens with its items.
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
        message = "Matched receipt with \(receipt.items.count) items. Check every line before approving."
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    @Binding var image: UIImage?
    let onSaved: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCaptureView

        init(_ parent: CameraCaptureView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
                parent.onSaved(image)
            }
            parent.dismiss()
        }
    }
}
#endif

#if os(macOS)
struct ReceiptView: View {
    let transaction: BankTransaction

    var body: some View { ApprovalView(transaction: transaction) }
}
#endif
