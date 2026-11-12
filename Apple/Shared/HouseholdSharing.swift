import BudgetCore
import CloudKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreTransferable
import LocalAuthentication
import SwiftUI
#if os(iOS)
import BackgroundTasks
import UIKit
#else
import AppKit
#endif

/// Hands a household invitation, opened from Messages, Mail or a link, to iCloud sync once
/// the person has seen who sent it and chosen Join. Anyone with the app can send an invitation
/// to any Apple ID, so opening one never shares anything by itself. It can arrive before sync
/// has started, so it waits until then.
@MainActor
final class ShareAcceptor {
    static let shared = ShareAcceptor()
    private var pending: CKShare.Metadata?
    /// The person chose Join; the invitation goes to sync as soon as sync is running.
    private var confirmed = false
    private var handler: ((CKShare.Metadata) async -> Void)?

    func receive(_ metadata: CKShare.Metadata) {
        print("[sync] Household invitation opened")
        pending = metadata
        confirmed = false
        AppModel.syncStatus.invite = .confirming(Self.inviter(metadata))
    }

    /// Who sent the invitation, as iCloud knows them: name and Apple ID where available.
    static func inviter(_ metadata: CKShare.Metadata) -> String {
        let identity = metadata.ownerIdentity
        let name = identity.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        let contact = identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber
        switch (name, contact) {
        case let (name?, contact?): return "\(name) (\(contact))"
        case let (name?, nil): return name
        case let (nil, contact?): return contact
        case (nil, nil): return "Someone whose name iCloud didn't give"
        }
    }

    /// The person chose Not Now: nothing is shared.
    func decline() {
        pending = nil
        confirmed = false
        AppModel.syncStatus.invite = nil
    }

    /// The person chose Join.
    func confirm() {
        guard let metadata = pending else { return }
        confirmed = true
        if let handler {
            pending = nil
            confirmed = false
            AppModel.syncStatus.invite = .joining
            Task { await handler(metadata) }
        } else {
            // Sync starts a moment after launch; say so if it can't start at all.
            pending = metadata
            if !AppModel.settings.iCloudSyncEnabled {
                AppModel.syncStatus.invite = .waitingForSync("Turn on Settings › Sync with iCloud in Duo Budget, then open the invitation again.")
            } else if CloudSync.containerID == nil {
                AppModel.syncStatus.invite = .waitingForSync("This copy of Duo Budget isn't signed for iCloud, so it can't join a household. Reinstall it from the Mac or TestFlight.")
            } else {
                AppModel.syncStatus.invite = .joining
            }
        }
    }

    func setHandler(_ handler: @escaping (CKShare.Metadata) async -> Void) {
        self.handler = handler
        if confirmed, let pending {
            self.pending = nil
            confirmed = false
            AppModel.syncStatus.invite = .joining
            Task { await handler(pending) }
        }
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// iCloud tells the app about changes from other devices with silent pushes, which wake it
    /// in the background (even when the phone is locked) so the sync engine can fetch them.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    /// A silent push from iCloud: something changed on another device. Fetch it now.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await AppModel.syncInBackground()
        return .newData
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in ShareAcceptor.shared.receive(metadata) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in ShareAcceptor.shared.receive(metadata) }
    }
}
#else
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in ShareAcceptor.shared.receive(metadata) }
    }
}
#endif

/// What the share sheet sends: an iCloud invitation to the household.
struct HouseholdInvite: Transferable {
    let sync: CloudSync

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { invite in
            // Only the people invited can join (no "Anyone with the link"), and they can make changes.
            .prepareShare(container: CKContainer(identifier: CloudSync.containerID ?? ""),
                          allowedSharingOptions: CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                                                         allowedParticipantAccessOptions: .specifiedRecipientsOnly)) {
                try await invite.sync.prepareShare()
            }
        }
    }
}

/// Settings › Partner: invite, see who's joined, leave or stop sharing, and put back what
/// was changed or deleted on another device.
struct HouseholdSharingSection: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var syncStatus: SyncStatus
    @State private var confirmingLeave = false
    @State private var error: String?

    var body: some View {
        Section {
            switch syncStatus.household.role {
            case .solo:
                if let sync = syncStatus.sync {
                    ShareLink(item: HouseholdInvite(sync: sync), preview: SharePreview("Join my Duo Budget household")) {
                        Label("Invite your partner", systemImage: "person.badge.plus")
                    }
                    inviteByCodeLink
                } else {
                    Text("Turn on iCloud sync to share your household.").foregroundStyle(.secondary)
                }
            case .owner:
                ForEach(syncStatus.participants, id: \.self) { Label($0, systemImage: "person") }
                if let sync = syncStatus.sync {
                    ShareLink(item: HouseholdInvite(sync: sync), preview: SharePreview("Join my Duo Budget household")) {
                        Label("Invite again", systemImage: "person.badge.plus")
                    }
                    inviteByCodeLink
                }
                Button("Stop Sharing", role: .destructive) { confirmingLeave = true }
            case .member:
                LabeledContent("Household", value: "Shared by \(syncStatus.household.sharedBy)")
                Button("Leave Household", role: .destructive) { confirmingLeave = true }
            }
            NavigationLink {
                RecentChangesView()
            } label: {
                LabeledContent("Recently changed or deleted", value: "\(store.recentChanges.count)")
            }
            if let error { Text(error).font(.caption).foregroundStyle(Color.brandPink) }
        } header: {
            Text("Partner")
        } footer: {
            Text(footer)
        }
        .task { await syncStatus.sync?.refreshParticipants() }
        .alert(syncStatus.household.role == .member ? "Leave the household?" : "Stop sharing?", isPresented: $confirmingLeave) {
            Button("Cancel", role: .cancel) {}
            Button(syncStatus.household.role == .member ? "Leave" : "Stop Sharing", role: .destructive) {
                Task {
                    do { try await syncStatus.sync?.leaveHousehold() } catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("Your own data stays on your devices. What was already shared stays on the other person's devices: iCloud can't take it back.")
        }
    }

    private var inviteByCodeLink: some View {
        NavigationLink { InviteCodeView() } label: {
            Label("Invite with a QR code or link", systemImage: "qrcode")
        }
    }

    private var footer: String {
        switch syncStatus.household.role {
        case .solo: "Your partner gets a link to join. Everything is shared unless you mark it Private, and it stays end-to-end encrypted: only the two of you can read it."
        case .owner: "Only you can change the couple settings and your own accounts. Anything your partner changes or deletes can be put back from Recently changed for 30 days. Marking an item Private hides it from now on; copies already shared stay with them."
        case .member: "Only the household owner can change the couple settings and their accounts. Your private items stay on your own devices."
        }
    }
}

/// Invite by QR code, AirDrop or a copied link. The link names the partner's Apple ID, so
/// only they can open it; anyone else who scans it is turned away by iCloud.
struct InviteCodeView: View {
    @EnvironmentObject var syncStatus: SyncStatus
    @State private var contact = ""
    @State private var link: URL?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Email or phone number", text: $contact)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                Button {
                    Task { await makeLink() }
                } label: {
                    if working { ProgressView() } else { Text(link == nil ? "Make Invitation" : "Make a New Invitation") }
                }
                .disabled(contact.trimmingCharacters(in: .whitespaces).isEmpty || working)
            } header: {
                Text("Your partner's Apple ID")
            } footer: {
                Text("The email address or phone number (with country code, like +44) they sign in to iCloud with. Only that Apple ID can open the invitation.")
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.brandPink) }
            }
            if let link {
                Section {
                    if let code = QRCode.image(for: link.absoluteString) {
                        Image(decorative: code, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 240)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .accessibilityLabel("QR code for the household invitation")
                    }
                    ShareLink(item: link, subject: Text("Join my Duo Budget household")) {
                        Label("AirDrop or Send Link…", systemImage: "square.and.arrow.up")
                    }
                    Button { copy(link) } label: { Label("Copy Link", systemImage: "doc.on.doc") }
                } footer: {
                    Text("On their iPhone: open the Camera, point it at the code and tap the link. Duo Budget opens and joins the household.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Invite with a Code")
    }

    private func makeLink() async {
        guard let sync = syncStatus.sync else {
            error = "Turn on Sync with iCloud first."
            return
        }
        working = true
        error = nil
        defer { working = false }
        do {
            link = try await sync.inviteLink(for: contact)
        } catch let failure as CKError where failure.code == .unknownItem {
            error = "No Apple ID was found for \(contact). Check the email or phone number they use for iCloud."
        } catch {
            self.error = CloudSync.describe(error)
        }
    }

    private func copy(_ url: URL) {
        #if os(iOS)
        UIPasteboard.general.url = url
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
    }
}

/// A QR code for a piece of text, drawn by Core Image on the device.
enum QRCode {
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// Items another device or the partner changed or deleted in the last 30 days, with Restore.
struct RecentChangesView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    @State private var confirmingRestoreAll = false

    private var deletions: [RecentChange] { store.recentChanges.filter { $0.kind == .deleted } }

    private func restore(_ change: RecentChange) {
        if change.collection == "contracts" {
            subscriptions.restore(change)
            store.forget(change)
        } else {
            store.restore(change)
        }
    }

    var body: some View {
        List {
            ForEach(store.recentChanges) { change in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.summary).lineLimit(1)
                        Text("\(change.kind == .deleted ? "Deleted" : "Changed")\(change.byPartner ? " by your partner" : " on another device") · \(change.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { restore(change) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .overlay {
            if store.recentChanges.isEmpty {
                ContentUnavailableView("Nothing changed elsewhere", systemImage: "clock.arrow.circlepath",
                                       description: Text("Items changed or deleted on another device or by your partner appear here for 30 days."))
            }
        }
        .toolbar {
            // Many items deleted at once (a reset or a mistake on another device) come back in one go.
            if deletions.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Button("Restore All Deleted") { confirmingRestoreAll = true }
                }
            }
        }
        .confirmationDialog("Restore \(deletions.count) deleted items?", isPresented: $confirmingRestoreAll, titleVisibility: .visible) {
            Button("Restore \(deletions.count) Items") { for change in deletions { restore(change) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They come back on this device and on every device that shares them.")
        }
        .navigationTitle("Recently changed")
    }
}

/// Settings › iCloud: sends every item again, for when something seems missing elsewhere.
struct SendEverythingAgainRow: View {
    @EnvironmentObject var syncStatus: SyncStatus
    @State private var sent = false

    var body: some View {
        Button(sent ? "Sending everything…" : "Send Everything Again") {
            sent = true
            Task { await syncStatus.sync?.sendEverythingAgain() }
        }
        .disabled(sent || syncStatus.sync == nil)
    }
}

/// Settings › iCloud: deletions held back because there were suspiciously many.
struct HeldDeletionsRow: View {
    @EnvironmentObject var syncStatus: SyncStatus

    var body: some View {
        if syncStatus.heldDeletions > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(syncStatus.heldDeletions) deletions are waiting", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.brandPink)
                Text("So many items disappeared at once that sync paused, in case something went wrong. Restore brings them back from iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Restore from iCloud") { Task { await syncStatus.sync?.restoreFromCloud() } }
                        .buttonStyle(.borderedProminent)
                    Button("Delete Them", role: .destructive) { Task { await syncStatus.sync?.confirmLargeDeletion() } }
                }
            }
        }
    }
}

/// Erase All Data, guarded: Face ID or the passcode, then typing ERASE.
struct EraseAllDataView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    @EnvironmentObject var syncStatus: SyncStatus
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var verified = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text("This deletes every transaction, budget, receipt, account, contract and shared file:")
                Label("on this device", systemImage: "iphone")
                Label("on your other devices that sync with iCloud", systemImage: "icloud")
                if syncStatus.household.role != .solo {
                    Label("the shared household items on your partner's devices (they can restore them for 30 days)", systemImage: "person.2")
                }
                Text("Your settings are kept. It can't be undone; export a CSV first if you want a copy.")
                    .foregroundStyle(.secondary)
            }
            if !verified {
                Section {
                    Button("Confirm with \(AppLock().methodName)") { Task { await verify() } }
                }
            } else {
                Section {
                    TextField("Type ERASE", text: $phrase)
                        .autocorrectionDisabled()
                    Button("Erase Everything", role: .destructive) { erase() }
                        .disabled(phrase.trimmingCharacters(in: .whitespaces) != "ERASE")
                } footer: {
                    Text("Type ERASE in capitals to confirm.")
                }
            }
            if let message { Text(message).foregroundStyle(Color.brandPink) }
        }
        .formStyle(.grouped)
        .navigationTitle("Erase All Data")
    }

    private func verify() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = "Set a passcode on this device to erase data."
            return
        }
        do {
            verified = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Erase all Duo Budget data")
        } catch {
            message = error.localizedDescription
        }
    }

    private func erase() {
        store.resetAllData()
        subscriptions.resetAllData()
        if let drop = SharedReceiptDrop.folder {
            for file in (try? FileManager.default.contentsOfDirectory(at: drop, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: file)
            }
        }
        // An erase on purpose is the one time many deletions go out without being held back.
        Task { await syncStatus.sync?.confirmLargeDeletion() }
        dismiss()
    }
}

/// Shown instead of the app while it isn't in front and the app lock is on.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color.brandIndigo.ignoresSafeArea()
            Label("Duo Budget", systemImage: "lock.fill")
                .font(.title2.bold())
                .foregroundStyle(.white)
        }
    }
}

#if os(macOS)
/// Locks the Mac app when the screen sleeps or locks, or the Mac goes to sleep.
@MainActor
final class MacLockWatcher {
    static let shared = MacLockWatcher()
    private var observers: [NSObjectProtocol] = []

    func watch(_ lock: AppLock) {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in lock.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in lock.lock() }
        })
    }
}
#endif

#if os(iOS)
/// Asks iOS for a background refresh every few hours, so changes go up and come down even
/// when the app hasn't been opened. iOS decides the exact time.
enum BackgroundSync {
    static let identifier = "com.nishantkumar.budgetreceipts.sync"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
