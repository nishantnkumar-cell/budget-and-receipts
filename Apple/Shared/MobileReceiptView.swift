import BudgetCore
import SwiftUI

#if os(iOS)
import PhotosUI
import UIKit

/// iPhone receipt flow: pick or photograph a receipt, OCR it on the device, correct it, approve.
struct ReceiptView: View {
    @EnvironmentObject var store: BudgetStore
    let transaction: BankTransaction
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var editor = ReceiptDraftEditor()
    @State private var reviewed = false
    @State private var message = "Choose or photograph a receipt, then review every item."
    private let vision = ReceiptVisionService()

    private var balanced: Bool { abs(abs(transaction.amount) - editor.splitTotal) <= SplitApprovalPolicy().tolerance }

    var body: some View {
        Form {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose receipt photo", systemImage: "photo")
            }
            .onChange(of: pickerItem) { _, newItem in load(newItem) }
            NavigationLink {
                CameraCaptureView(image: $image, onSaved: { scan($0) })
            } label: {
                Label("Use camera", systemImage: "camera")
            }
            Section("Receipt") {
                TextField("Merchant", text: $editor.merchant)
                TextField("Total", value: $editor.receiptTotal, format: .number).decimalKeyboard()
            }
            Section("Items") {
                ForEach($editor.items) { $line in
                    VStack {
                        TextField("Description", text: $line.description)
                        HStack {
                            TextField("Amount", value: $line.total, format: .number).decimalKeyboard()
                            Picker("Category", selection: $line.category) {
                                ForEach(FinanceCategories.all, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        if store.hasPartner {
                            OwnerPicker(owner: $line.owner)
                        }
                    }
                }
                .onDelete { editor.items.remove(atOffsets: $0) }
                Button("Add item") { editor.addItem() }
            }
            ReconciliationSection(bankAmount: transaction.amount, splitTotal: editor.splitTotal, balanced: balanced)
            Section {
                Toggle("I checked every item", isOn: $reviewed)
                Text(message).font(.caption)
                Button("Save draft") {
                    store.saveDraft(editor.makeDraft(reviewed: false), for: transaction)
                    message = store.status
                }
                Button("Approve split") {
                    store.approve(editor.makeDraft(reviewed: reviewed), for: transaction)
                    message = store.status
                }
                .disabled(!reviewed || !balanced || editor.items.isEmpty)
            }
        }
        .navigationTitle("Receipt")
    }

    private func load(_ item: PhotosPickerItem?) {
        Task {
            guard let data = try? await item?.loadTransferable(type: Data.self), let picked = UIImage(data: data) else { return }
            image = picked
            scan(picked, data: data)
        }
    }

    private func scan(_ picked: UIImage, data: Data? = nil) {
        Task {
            do {
                var result = try await vision.recognise(image: picked)
                // Keep the receipt so it can be looked at again after approval.
                if let saved = data ?? picked.jpegData(compressionQuality: 0.8) {
                    result.imagePath = (try? ReceiptImageStore().save(saved)) ?? ""
                }
                editor = result
                message = "OCR complete. Correct the draft before approval."
            } catch {
                message = error.localizedDescription
            }
        }
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
