import BudgetCore
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import UIKit
#endif

/// Scan tab: photograph or pick a receipt, read it on the device, then attach it to the
/// matching card payment. The receipt then waits in the Inbox for approval.
struct CaptureView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var editor: ReceiptDraftEditor?
    @State private var imageName = ""
    @State private var reading = false
    @State private var message: String?
    @State private var saved: String?
    private let vision = ReceiptVisionService()
    #if os(iOS)
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var cameraImage: UIImage?
    #else
    @State private var choosingFile = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                sources
                if reading {
                    ProgressView("Reading the receipt…").card()
                }
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary).card()
                }
                if let saved {
                    Label(saved, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .card()
                }
                if let editor {
                    ScannedSummary(editor: editor)
                    matches(for: editor)
                }
                NavigationLink { ImportStatementView() } label: {
                    Label("Import a bank statement", systemImage: "doc.badge.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .card()
            }
            .padding()
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .appBackground()
        .navigationTitle("Scan receipt")
        #if os(iOS)
        .onChange(of: pickerItem) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                await read(data)
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCaptureView(image: $cameraImage) { image in
                guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                Task { await read(data) }
            }
            .ignoresSafeArea()
        }
        #else
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            readFile(url)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            readFile(url)
            return true
        }
        #endif
    }

    @ViewBuilder private var sources: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 44))
                .foregroundStyle(Color.brandPink)
            Text("Receipts are read on this device. Nothing is uploaded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #if os(iOS)
            HStack(spacing: 12) {
                Button { showingCamera = true } label: {
                    Label("Take photo", systemImage: "camera").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Photos", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            #else
            Button { choosingFile = true } label: { Label("Choose Receipt Image…", systemImage: "photo") }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("or drop a receipt photo anywhere on this page")
                .font(.caption)
                .foregroundStyle(.secondary)
            #endif
        }
        .frame(maxWidth: .infinity)
        .card(padding: 20)
    }

    /// Spending payments this receipt could belong to, closest total and date first.
    private func candidates(for editor: ReceiptDraftEditor) -> [BankTransaction] {
        let total = editor.receiptTotal ?? editor.splitTotal
        let date = editor.purchaseDate ?? Date()
        return store.transactions
            .filter { $0.amount < 0 && $0.splits.isEmpty }
            .sorted { lhs, rhs in
                let lhsExact = abs(lhs.amount) == total, rhsExact = abs(rhs.amount) == total
                if lhsExact != rhsExact { return lhsExact }
                return abs(lhs.date.timeIntervalSince(date)) < abs(rhs.date.timeIntervalSince(date))
            }
            .prefix(5)
            .map { $0 }
    }

    @ViewBuilder private func matches(for editor: ReceiptDraftEditor) -> some View {
        let total = editor.receiptTotal ?? editor.splitTotal
        VStack(alignment: .leading, spacing: 12) {
            CardHeader("Which payment is this?")
            let options = candidates(for: editor)
            if options.isEmpty {
                Text("No card payments yet. Import a statement or add the payment first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(options) { transaction in
                Button { attach(editor, to: transaction) } label: {
                    HStack {
                        TransactionRow(transaction: transaction)
                        if abs(transaction.amount) == total {
                            Text("Match").font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .foregroundStyle(Color.brandInk)
                                .background(Color.brandAmber, in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    private func attach(_ editor: ReceiptDraftEditor, to transaction: BankTransaction) {
        var draft = editor
        draft.imagePath = imageName
        store.saveDraft(draft.makeDraft(reviewed: false), for: transaction)
        saved = "Saved to \(transaction.merchant). Check and approve it in the Inbox."
        self.editor = nil
    }

    #if os(macOS)
    private func readFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            message = "Couldn't open that file."
            return
        }
        Task { await read(data, fileExtension: url.pathExtension.isEmpty ? "jpg" : url.pathExtension) }
    }
    #endif

    @MainActor private func read(_ data: Data, fileExtension: String = "jpg") async {
        reading = true
        saved = nil
        message = nil
        defer { reading = false }
        do {
            editor = try await vision.recognise(data: data)
            imageName = (try? ReceiptImageStore().save(data, fileExtension: fileExtension)) ?? ""
        } catch {
            editor = nil
            message = "Couldn't read any text. Try a sharper photo with the whole receipt in view."
        }
    }
}

/// What was read from the receipt, as chips.
struct ScannedSummary: View {
    let editor: ReceiptDraftEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Read on this device", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brandAmber)
            HStack(spacing: 8) {
                if !editor.merchant.isEmpty { chip(editor.merchant) }
                if let total = editor.receiptTotal { chip(total.money) }
                chip(editor.items.count == 1 ? "1 item" : "\(editor.items.count) items")
            }
        }
        .card()
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.brandPlum.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
