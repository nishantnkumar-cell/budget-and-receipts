import AppIntents
import Foundation

/// Opens Duo Budget on Scan. Used by the Control Centre button and by Siri and Shortcuts.
/// It's compiled into both the app and the widgets, which reach the app by its link.
struct OpenScanIntent: AppIntent {
    static let title: LocalizedStringResource = "Scan a Receipt"
    static let description = IntentDescription("Opens Duo Budget ready to scan a receipt.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "duobudget://scan")!))
    }
}
