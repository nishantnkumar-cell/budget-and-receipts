import BudgetCore
import PDFKit
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import VisionKit
#endif

/// Keeps contract documents next to the app's data, in the same folder as receipt photos, so
/// they go to iCloud the same way: only inside end-to-end encrypted fields (see CloudSync).
struct ContractDocumentStore {
    let folder: URL

    init(dataFolder: URL = JSONFileStorage.defaultFolder) {
        folder = ReceiptImageStore(dataFolder: dataFolder).folder
    }

    /// Saves a PDF as it is, or an image without its metadata (no location or camera details),
    /// and returns the stored file name.
    func save(_ data: Data, isPDF: Bool) throws -> String {
        if isPDF {
            guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            // Without its author, title, software and dates, like photos without their location.
            document.documentAttributes = [:]
            let clean = document.dataRepresentation() ?? data
            let name = "\(UUID().uuidString).pdf"
            try clean.write(to: folder.appendingPathComponent(name), options: ReceiptImageStore.writeOptions)
            return name
        }
        guard ReceiptImageStore.withoutMetadata(data) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return try ReceiptImageStore(dataFolder: folder.deletingLastPathComponent()).save(data)
    }

    func url(for document: ContractDocument) -> URL? {
        let url = folder.appendingPathComponent((document.fileName as NSString).lastPathComponent)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func remove(_ document: ContractDocument) {
        if let url = url(for: document) { try? FileManager.default.removeItem(at: url) }
    }

    /// True when the file is small enough to go to iCloud. Bigger PDFs stay on this device.
    func syncs(_ document: ContractDocument) -> Bool {
        guard document.isPDF else { return true }
        guard let url = url(for: document), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return true }
        return size <= CloudSync.maxDocumentBytes
    }

    /// One PDF from scanned pages, each page a compressed JPEG so a few pages still fit in iCloud.
    static func pdf(from images: [CGImage]) -> Data? {
        let document = PDFDocument()
        for (index, image) in images.enumerated() {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.55, kCGImageDestinationImageMaxPixelSize: 1700] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            #if os(iOS)
            guard let page = UIImage(data: output as Data).flatMap(PDFPage.init(image:)) else { continue }
            #else
            guard let page = NSImage(data: output as Data).flatMap(PDFPage.init(image:)) else { continue }
            #endif
            document.insert(page, at: index)
        }
        return document.pageCount > 0 ? document.dataRepresentation() : nil
    }
}

/// The Documents section of a contract: list, open, rename, remove, and add by scanning,
/// choosing a photo or picking a file.
struct ContractDocumentsSection: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Binding var documents: [ContractDocument]?
    /// Files added and removed while editing, so Cancel can undo them.
    @Binding var added: [ContractDocument]
    @Binding var removed: [ContractDocument]
    @State private var preview: URL?
    @State private var choosingFile = false
    @State private var photo: PhotosPickerItem?
    @State private var scanning = false
    @State private var renaming: ContractDocument?
    @State private var newTitle = ""
    @State private var error: String?
    private var files: ContractDocumentStore { subscriptions.documentFiles }

    private var list: [ContractDocument] { documents ?? [] }

    var body: some View {
        Section {
            ForEach(list) { document in
                DeletableRow(label: "Remove", onDelete: { remove(document) }) {
                    Button { preview = files.url(for: document) } label: { row(document) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { renaming = document; newTitle = document.title } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { remove(document) } label: { Label("Remove", systemImage: "trash") }
                        }
                }
            }
            addMenu
        } header: {
            Label("Documents", systemImage: "paperclip")
        } footer: {
            Text("Keep the signed contract or summary here. Files stay on your devices and in end-to-end encrypted iCloud, shared with your partner unless the contract is private.")
        }
        .quickLookPreview($preview)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pdf, .image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { error = "That file couldn't be read."; return }
            add(data, isPDF: UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true, title: url.deletingPathExtension().lastPathComponent)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { add(data, isPDF: false, title: "Photo") }
                photo = nil
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner { images in
                scanning = false
                if let images, let data = ContractDocumentStore.pdf(from: images) { add(data, isPDF: true, title: "Scanned contract") }
            }
            .ignoresSafeArea()
        }
        #endif
        .alert("Rename document", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                let title = newTitle.trimmingCharacters(in: .whitespaces)
                if let renaming, !title.isEmpty, let index = documents?.firstIndex(where: { $0.id == renaming.id }) { documents?[index].title = title }
                renaming = nil
            }
        }
        .alert("Couldn't add the document", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ document: ContractDocument) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: document.isPDF ? "doc.richtext" : "photo", size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title).font(.body.weight(.medium)).lineLimit(1)
                Text(detail(document)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "eye").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the document")
    }

    private func detail(_ document: ContractDocument) -> String {
        let added = "Added \(document.added.formatted(.dateTime.day().month(.abbreviated).year()))"
        if files.url(for: document) == nil { return "\(added) · still arriving from iCloud" }
        return files.syncs(document) ? added : "\(added) · too big for iCloud, on this device only"
    }

    private var addMenu: some View {
        Menu {
            #if os(iOS)
            if VNDocumentCameraViewController.isSupported {
                Button { scanning = true } label: { Label("Scan Document", systemImage: "doc.viewfinder") }
            }
            #endif
            PhotosPicker(selection: $photo, matching: .images) { Label("Choose Photo", systemImage: "photo.on.rectangle") }
            Button { choosingFile = true } label: { Label("Choose File", systemImage: "folder") }
        } label: {
            Label("Add Document", systemImage: "plus")
        }
        #if os(macOS)
        .menuStyle(.button)
        .fixedSize()
        #endif
    }

    private func add(_ data: Data, isPDF: Bool, title: String) {
        do {
            let name = try files.save(data, isPDF: isPDF)
            let document = ContractDocument(fileName: name, title: title.isEmpty ? "Document" : title)
            documents = list + [document]
            added.append(document)
            subscriptions.noteUnsaved(document)
        } catch {
            self.error = isPDF ? "That PDF couldn't be read." : "That isn't a photo the app can read."
        }
    }

    private func remove(_ document: ContractDocument) {
        documents = list.filter { $0.id != document.id }
        if let index = added.firstIndex(of: document) {
            added.remove(at: index)
            files.remove(document)
        } else {
            removed.append(document)
        }
        if documents?.isEmpty == true { documents = nil }
    }
}

#if os(iOS)
/// The system document scanner (edge detection, flattening, several pages).
struct DocumentScanner: UIViewControllerRepresentable {
    /// The scanned pages, or nil when cancelled.
    let done: ([CGImage]?) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let done: ([CGImage]?) -> Void
        init(done: @escaping ([CGImage]?) -> Void) { self.done = done }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            done((0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { done(nil) }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { done(nil) }
    }
}
#endif
