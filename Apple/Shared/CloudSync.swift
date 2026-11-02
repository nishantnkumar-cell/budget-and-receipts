import BudgetCore
import CloudKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What iCloud sync last did, for Settings.
@MainActor
final class SyncStatus: ObservableObject {
    /// For the sync indicator (a cloud on iPhone Home, a toolbar item on the Mac).
    enum State: Equatable {
        /// Sync is switched off, or this build has no iCloud.
        case off
        case syncing
        /// Everything on this device is in iCloud and nothing is waiting.
        case upToDate
        /// Changes are waiting to be sent, e.g. with no internet. They go when it's back.
        case pendingOffline
        /// Something needs the person: signed out of iCloud, storage full and so on.
        case error(String)
    }

    @Published private(set) var state: State = .off
    /// When everything was last confirmed in step with iCloud.
    @Published private(set) var lastSynced: Date?
    /// Changes on this device not yet in iCloud.
    @Published private(set) var pendingCount = 0
    /// One line for Settings, e.g. "Up to date · 17:20".
    @Published var text = "Not synced yet."

    func update(_ text: String) {
        self.text = text + " · " + Date().formatted(date: .omitted, time: .shortened)
    }

    func set(_ state: State, pending: Int) {
        self.state = state
        pendingCount = pending
        if state == .upToDate { lastSynced = Date() }
    }
}

/// A store whose items sync with iCloud.
@MainActor
protocol SyncSource: AnyObject, Sendable {
    func syncRecords() -> [SyncRecord]
    func applySync(saves: [SyncRecord], deletes: Set<String>)
}

/// Keeps the app's data in step across your devices with iCloud (CloudKit), in your own
/// private iCloud database. Shared items live in the "Household" zone, which can later be
/// shared with a partner; items marked private live in the "Private" zone and never are.
/// Only items that changed are sent; the data never goes to any server but Apple's iCloud.
///
/// Everything is end-to-end encrypted: each item's JSON, its ids and any receipt photo are in
/// CloudKit's `encryptedValues`, whose keys live in the person's iCloud Keychain (and are given
/// only to people a zone is shared with). Record names are hashes, so nothing is readable in
/// plain text, with or without Advanced Data Protection.
actor CloudSync: CKSyncEngineDelegate {
    static let householdZone = CKRecordZone.ID(zoneName: "HouseholdE2E")
    static let privateZone = CKRecordZone.ID(zoneName: "PrivateE2E")
    /// Zones from the first version, which kept data in plain fields. Deleted on upgrade.
    static let legacyZones = [CKRecordZone.ID(zoneName: "Household"), CKRecordZone.ID(zoneName: "Private")]
    /// Receipt photos are shrunk to stay inside CloudKit's 1 MB record limit.
    static let maxImageBytes = 700_000

    /// The iCloud container, read from Info.plist. Nil in builds without iCloud (tests, unsigned).
    /// Also nil whenever this copy of the app isn't signed for it: CloudKit stops the app outright
    /// if it's asked for a container it has no permission for (an iPhone build run on a Mac, for
    /// example), so the app runs without sync instead.
    nonisolated static var containerID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainer") as? String,
              isSigned(for: id) else { return nil }
        return id
    }

    /// True when the app's provisioning profile grants the iCloud container.
    nonisolated static func isSigned(for container: String) -> Bool {
        let candidates = [
            Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile"),
        ].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .isoLatin1),
                  let start = text.range(of: "<?xml"),
                  let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex) else { continue }
            let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)
            guard let profile = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
                  let entitlements = profile["Entitlements"] as? [String: Any] else { continue }
            let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
            if containers.contains(container) || containers.contains("*") { return true }
        }
        return false
    }

    private let sources: [SyncSource]
    private let status: SyncStatus?
    private let imagesFolder: URL
    private let stateFolder: URL
    private var engine: CKSyncEngine?
    private var state: SyncState
    /// iCloud's bookkeeping for each record (its change tag), so saves don't conflict.
    private var systemFields: [String: Data]
    /// Records waiting to be sent, by iCloud record name.
    private var outgoing: [String: SyncRecord] = [:]

    init(sources: [SyncSource], imagesFolder: URL, stateFolder: URL, status: SyncStatus? = nil) {
        self.sources = sources
        self.status = status
        self.imagesFolder = imagesFolder
        self.stateFolder = stateFolder
        state = Self.load(SyncState.self, stateFolder.appendingPathComponent("sync-state.json")) ?? SyncState()
        systemFields = Self.load([String: Data].self, stateFolder.appendingPathComponent("sync-records.json")) ?? [:]
    }

    /// Starts syncing: fetches what changed elsewhere, then sends local changes.
    func start() async {
        guard engine == nil, let id = Self.containerID else { return }
        let database = CKContainer(identifier: id).privateCloudDatabase
        let saved = Self.load(CKSyncEngine.State.Serialization.self, stateFolder.appendingPathComponent("sync-engine.json"))
        let engine = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: saved, delegate: self))
        self.engine = engine
        let upgradeFlag = stateFolder.appendingPathComponent("sync-e2e-upgraded")
        if saved == nil || !FileManager.default.fileExists(atPath: upgradeFlag.path) {
            // First start, or upgrading from plain fields: remove the old zones from iCloud and
            // send everything again, encrypted. Nothing on this device is deleted.
            engine.state.add(pendingDatabaseChanges: Self.legacyZones.map { .deleteZone($0) }
                + [.saveZone(CKRecordZone(zoneID: Self.householdZone)), .saveZone(CKRecordZone(zoneID: Self.privateZone))])
            resetLocalSyncState()
            FileManager.default.createFile(atPath: upgradeFlag.path, contents: Data())
        }
        await fetch()
        await localDataChanged()
    }

    private func report(_ text: String) async {
        guard let status else { return }
        let pending = engine?.state.pendingRecordZoneChanges.count ?? 0
        let state: SyncStatus.State
        if text.hasPrefix("Couldn't") {
            state = pending > 0 ? .pendingOffline : .error(text)
        } else if text.hasPrefix("Sign") {
            state = .error(text)
        } else {
            state = pending > 0 ? .pendingOffline : .upToDate
        }
        await MainActor.run {
            status.update(text)
            status.set(state, pending: pending)
        }
    }

    private func reportSyncing() async {
        guard let status else { return }
        let pending = engine?.state.pendingRecordZoneChanges.count ?? 0
        await MainActor.run { status.set(.syncing, pending: pending) }
    }

    private func fetch() async {
        await reportSyncing()
        do {
            try await engine?.fetchChanges()
            await report("Up to date")
        } catch let error as CKError where error.code == .notAuthenticated {
            await report("Sign in to iCloud on this device to sync")
        } catch {
            await report("Couldn't reach iCloud: \(error.localizedDescription)")
        }
    }

    /// Call after local data is saved. Queues whatever changed since the last sync.
    func localDataChanged() async {
        guard let engine else { return }
        let current = await MainActor.run { sources.flatMap { $0.syncRecords() } }
        let changes = state.changes(to: current)
        guard !changes.isEmpty else { return }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for delete in changes.deletes {
            pending.append(.deleteRecord(recordID(delete.key, isPrivate: delete.isPrivate)))
            state.recordDeleted(delete.key)
        }
        for record in changes.saves {
            outgoing[Self.recordName(record.key)] = record
            pending.append(.saveRecord(recordID(record.key, isPrivate: record.isPrivate)))
        }
        engine.state.add(pendingRecordZoneChanges: pending)
        saveState()
        await reportSyncing()
        do {
            try await engine.sendChanges()
            await report("Sent \(changes.saves.count + changes.deletes.count) change\(changes.saves.count + changes.deletes.count == 1 ? "" : "s")")
        } catch {
            await report("Couldn't send changes: \(error.localizedDescription)")
        }
    }

    /// Fetches changes now, e.g. when the app comes to the front.
    func refresh() async {
        await fetch()
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Self.save(update.stateSerialization, stateFolder.appendingPathComponent("sync-engine.json"))

        case .accountChange(let change):
            if case .signOut = change.changeType { await report("Signed out of iCloud") }
            if case .switchAccounts = change.changeType { resetLocalSyncState() }
            if case .signOut = change.changeType { resetLocalSyncState() }

        case .fetchedRecordZoneChanges(let changes):
            var saves: [SyncRecord] = []
            for modification in changes.modifications {
                let record = modification.record
                guard let item = syncRecord(from: record) else { continue }
                systemFields[record.recordID.recordName] = encodeSystemFields(record)
                state.recordSaved(item)
                saves.append(item)
            }
            var deletes = Set<String>()
            for deletion in changes.deletions {
                let recordName = deletion.recordID.recordName
                guard let key = state.entries.keys.first(where: { Self.recordName($0) == recordName }) else {
                    systemFields[recordName] = nil
                    continue
                }
                // Moving between zones deletes from one and saves in the other: keep the save.
                guard !saves.contains(where: { $0.key == key }) else { continue }
                deletes.insert(key)
                state.recordDeleted(key)
                systemFields[recordName] = nil
            }
            saveState()
            if !saves.isEmpty || !deletes.isEmpty { await report("Received \(saves.count + deletes.count) change\(saves.count + deletes.count == 1 ? "" : "s")") }
            let finalSaves = saves, finalDeletes = deletes
            await MainActor.run {
                for source in sources { source.applySync(saves: finalSaves, deletes: finalDeletes) }
            }

        case .sentRecordZoneChanges(let sent):
            for record in sent.savedRecords {
                let key = record.recordID.recordName
                systemFields[key] = encodeSystemFields(record)
                if let item = outgoing.removeValue(forKey: key) { state.recordSaved(item) }
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            for failure in sent.failedRecordSaves {
                let key = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    // Someone else saved it first: keep their change tag and send ours again.
                    if let server = failure.error.serverRecord { systemFields[key] = encodeSystemFields(server) }
                    retry.append(.saveRecord(failure.record.recordID))
                case .zoneNotFound:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: failure.record.recordID.zoneID))])
                    retry.append(.saveRecord(failure.record.recordID))
                case .unknownItem:
                    systemFields[key] = nil
                    retry.append(.saveRecord(failure.record.recordID))
                default:
                    // Network or quota problems: CKSyncEngine retries on its own later.
                    break
                }
            }
            for id in sent.deletedRecordIDs { systemFields[id.recordName] = nil }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            saveState()

        case .fetchedDatabaseChanges(let changes):
            // A zone deleted on another device (e.g. "Reset iCloud data"): forget what was sent.
            if changes.deletions.contains(where: { $0.zoneID == Self.householdZone || $0.zoneID == Self.privateZone }) {
                resetLocalSyncState()
            }

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.ckRecord(for: recordID)
        }
    }

    // MARK: Records

    private func recordID(_ key: String, isPrivate: Bool) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName(key), zoneID: isPrivate ? Self.privateZone : Self.householdZone)
    }

    /// A record name that gives nothing away: a hash of the item's collection and id.
    static func recordName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func ckRecord(for id: CKRecord.ID) -> CKRecord? {
        guard let item = outgoing[id.recordName] else { return nil }
        var record = CKRecord(recordType: "Item", recordID: id)
        if let fields = systemFields[id.recordName], let saved = decodeSystemFields(fields), saved.recordID.zoneID == id.zoneID {
            record = saved
        }
        // All in encrypted fields: end-to-end encrypted, unreadable to anyone but the owner
        // (and, later, the people they share the household with).
        record.encryptedValues["collection"] = item.collection
        record.encryptedValues["itemID"] = item.id
        record.encryptedValues["payload"] = item.payload
        if let name = item.fileName, let image = Self.imageForUpload(imagesFolder.appendingPathComponent(name)) {
            record.encryptedValues["fileName"] = name
            record.encryptedValues["file"] = image
        }
        return record
    }

    private func syncRecord(from record: CKRecord) -> SyncRecord? {
        guard let collection = record.encryptedValues["collection"] as? String,
              let id = record.encryptedValues["itemID"] as? String else { return nil }
        var fileName: String?
        if let data = record.encryptedValues["file"] as? Data {
            let name = ((record.encryptedValues["fileName"] as? String ?? id) as NSString).lastPathComponent
            try? data.write(to: imagesFolder.appendingPathComponent(name), options: .atomic)
            fileName = name
        }
        return SyncRecord(
            collection: collection,
            id: id,
            payload: record.encryptedValues["payload"] as? Data ?? Data(),
            isPrivate: record.recordID.zoneID == Self.privateZone,
            fileName: fileName
        )
    }

    /// A receipt photo small enough for an encrypted field: shrunk until it fits under
    /// `maxImageBytes`, still easily readable. Nil when the file is missing.
    static func imageForUpload(_ url: URL) -> Data? {
        guard let original = try? Data(contentsOf: url) else { return nil }
        if original.count <= maxImageBytes { return original }
        guard let source = CGImageSourceCreateWithData(original as CFData, nil) else { return nil }
        for (side, quality) in [(2000, 0.7), (1600, 0.6), (1200, 0.5), (900, 0.45)] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= maxImageBytes { return output as Data }
        }
        return nil
    }

    private func encodeSystemFields(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    // MARK: Saved state

    /// After signing out or switching Apple ID, everything is sent again from scratch.
    private func resetLocalSyncState() {
        state = SyncState()
        systemFields = [:]
        outgoing = [:]
        saveState()
    }

    private func saveState() {
        Self.save(state, stateFolder.appendingPathComponent("sync-state.json"))
        Self.save(systemFields, stateFolder.appendingPathComponent("sync-records.json"))
    }

    private static func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
