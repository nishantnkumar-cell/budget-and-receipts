import UniformTypeIdentifiers
#if os(iOS)
import UIKit
typealias PlatformViewController = UIViewController
#else
import AppKit
typealias PlatformViewController = NSViewController
#endif

/// "Duo Budget" in the share sheet. It saves shared receipts (PDFs and images) and bank
/// statements (CSV, OFX, QFX, QIF) for the app; it does no reading itself, so it stays fast
/// and small. The app reads them when it opens.
final class ShareViewController: PlatformViewController {
    #if os(macOS)
    override var nibName: NSNib.Name? { nil }
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1)) }
    #endif

    #if os(iOS)
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await receive() }
    }
    #else
    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await receive() }
    }
    #endif

    @MainActor private func receive() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var saved = 0
        for provider in providers {
            for type in [UTType.pdf, .image, .data] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let (data, ext) = await load(provider, type: type), (try? SharedReceiptDrop.add(data, fileExtension: ext)) == true {
                    saved += 1
                }
                break
            }
        }
        #if os(iOS)
        // Say what happened, so a shared file never seems to vanish.
        let alert = saved == 0
            ? UIAlertController(title: "Not a supported file", message: "Duo Budget takes PDFs, photos and CSV, OFX, QFX or QIF statements.", preferredStyle: .alert)
            : UIAlertController(title: "Sent to Duo Budget", message: "Open the app to finish. Statements are imported and receipts wait for their payment. You'll find every file under Inbox › Shared files.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.finish(saved) })
        present(alert, animated: true)
        #else
        finish(saved)
        #endif
    }

    private func finish(_ saved: Int) {
        if saved == 0 {
            extensionContext?.cancelRequest(withError: CocoaError(.fileReadUnsupportedScheme))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func load(_ provider: NSItemProvider, type: UTType) async -> (Data, String)? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url, !SharedReceiptDrop.isTooLarge(url), let data = try? Data(contentsOf: url) else { return continuation.resume(returning: nil) }
                let ext = url.pathExtension.isEmpty ? (type == .pdf ? "pdf" : type == .image ? "jpg" : "") : url.pathExtension
                continuation.resume(returning: (data, ext))
            }
        }
    }
}
