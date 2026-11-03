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
    /// The size of the current upload, so progress can show "12 of 68".
    @Published private(set) var uploadTotal = 0
    /// The last thing that went wrong, kept until a sync succeeds.
    @Published private(set) var lastError: String?

    /// How far the current upload has got, from 0 to 1. Nil when nothing is uploading.
    var progress: Double? {
        guard uploadTotal > 0, pendingCount > 0 else { return nil }
        return Double(uploadTotal - min(pendingCount, uploadTotal)) / Double(uploadTotal)
    }

    func noteError(_ message: String?) { lastError = message }
    /// One line for Settings, e.g. "Up to date · 17:20".
    @Published var text = "Not synced yet."
    /// Deletions held back because there were suspiciously many; the person confirms or restores.
    @Published var heldDeletions = 0
    /// This device's place in a shared household.
    @Published var household: HouseholdLink = HouseholdLink()
    /// People in the household (for the owner), e.g. "priya@icloud.com (invited)".
    @Published var participants: [String] = []
    /// The running sync, for Settings' actions (invite, restore, leave). Nil when sync is off.
    var sync: CloudSync?

    func update(_ text: String) {
        self.text = text + " · " + Date().formatted(date: .omitted, time: .shortened)
    }

    func setHeld(_ count: Int) { heldDeletions = count }

    func set(_ state: State, pending: Int) {
        self.state = state
        pendingCount = pending
        // A new upload starts the bar again; it grows if more changes join it.
        if pending == 0 { uploadTotal = 0 } else if pending > uploadTotal { uploadTotal = pending }
        if state == .upToDate {
            lastSynced = Date()
            lastError = nil
        }
        if case .error(let message) = state { lastError = message }
    }
}

/// A store whose items sync with iCloud.
@MainActor
protocol SyncSource: AnyObject, Sendable {
    func syncRecords() -> [SyncRecord]
    /// Returns false when the changes couldn't be saved to disk.
    @discardableResult
    func applySync(saves: [SyncRecord], deletes: Set<String>) -> Bool
    /// Files that couldn't be read at launch; sync restores from iCloud when there are any.
    var unreadableFiles: [String] { get }
    /// True while the files are locked away; sync waits until they can be read.
    var isWaitingForFiles: Bool { get }
    /// Keys among these arrivals this store refused (not the partner's to change).
    func rejectedKeys(_ saves: [SyncRecord]) -> Set<String>
}

extension SyncSource {
    func rejectedKeys(_ saves: [SyncRecord]) -> Set<String> { [] }
    var isWaitingForFiles: Bool { false }
}

/// Where this device stands in a shared household.
struct HouseholdLink: Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        /// Not shared (or not shared yet).
        case solo
        /// Created the household and invited a partner.
        case owner
        /// Joined someone else's household.
        case member
    }

    var role: Role = .solo
    /// For a member: the owner's household zone.
    var zoneName = ""
    var zoneOwner = ""
    /// For a member: who shared it, to show "Shared by …".
    var sharedBy = ""
}

/// Keeps the app's data in step across your devices, and with a partner, through iCloud
/// (CloudKit). There is no server of our own.
///
/// - Shared items live in a household zone: your own (`HouseholdE2E`, in your private database)
///   or, after joining a partner's household, theirs (through the shared database). Items
///   marked private live in `PrivateE2E` in your own private database and are never shared.
/// - Everything is end-to-end encrypted: each item's ids, JSON and any receipt photo are only in
///   `encryptedValues`, whose keys live in iCloud Keychain and go only to share participants.
///   Record names are random, so nothing about an item can be read or guessed from them.
/// - Safety: an unreadable local file triggers a restore from iCloud, never deletions; large
///   deletions are held until the person confirms; a change is marked synced only once it is
///   saved on disk.
actor CloudSync: CKSyncEngineDelegate {
    static let householdZone = CKRecordZone.ID(zoneName: "HouseholdE2E")
    static let privateZone = CKRecordZone.ID(zoneName: "PrivateE2E")
    /// Zones from the first version, which kept data in plain fields. Deleted on every launch,
    /// in case a device still on the old version re-created them.
    static let legacyZones = [CKRecordZone.ID(zoneName: "Household"), CKRecordZone.ID(zoneName: "Private")]
    /// The record type for items. The first version's "Item" type has plain (unencrypted) fields
    /// in the iCloud schema, and a field's type can never change, so encrypted items need a
    /// type of their own: saving encrypted values into "Item" is refused.
    static let recordType = "SealedItem"
    /// Receipt photos are shrunk to stay inside CloudKit's 1 MB record limit.
    static let maxImageBytes = 700_000
    /// More deletions than this at once (or more than a fifth of everything) wait for the person.
    static let largeDeletion = 25

    /// The iCloud container, read from Info.plist. Nil in builds without iCloud (tests, unsigned)
    /// and whenever this copy of the app isn't signed for it: CloudKit stops the app outright
    /// if it's asked for a container it has no permission for (an iPhone build run on a Mac,
    /// for example), so the app runs without sync instead.
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
    private var container: CKContainer?
    private var privateEngine: CKSyncEngine?
    private var sharedEngine: CKSyncEngine?
    private var state: SyncState
    private var household: HouseholdLink
    /// Record name for each item key. Names are random; this map is how they're found.
    private var names: [String: String]
    /// iCloud's bookkeeping for each record (its change tag), so saves don't conflict.
    private var systemFields: [String: Data]
    /// Records waiting to be sent, by iCloud record name.
    private var outgoing: [String: SyncRecord] = [:]
    /// Deletions waiting for the person's confirmation.
    private var heldDeletes: [SyncChanges.Delete] = []
    private var allowLargeDeletionOnce = false

    init(sources: [SyncSource], imagesFolder: URL, stateFolder: URL, status: SyncStatus? = nil) {
        self.sources = sources
        self.status = status
        self.imagesFolder = imagesFolder
        self.stateFolder = stateFolder
        state = Self.load(SyncState.self, stateFolder.appendingPathComponent("sync-state.json")) ?? SyncState()
        systemFields = Self.load([String: Data].self, stateFolder.appendingPathComponent("sync-records.json")) ?? [:]
        names = Self.load([String: String].self, stateFolder.appendingPathComponent("sync-names.json")) ?? [:]
        household = Self.load(HouseholdLink.self, stateFolder.appendingPathComponent("household.json")) ?? HouseholdLink()
    }

    private var householdZoneID: CKRecordZone.ID {
        household.role == .member ? CKRecordZone.ID(zoneName: household.zoneName, ownerName: household.zoneOwner) : Self.householdZone
    }

    /// Starts syncing: fetches what changed elsewhere, then sends local changes.
    func start() async {
        guard privateEngine == nil, let id = Self.containerID else { return }
        // Locked files would look like no data: wait until the app can read them.
        guard await MainActor.run(body: { !sources.contains { $0.isWaitingForFiles } }) else { return }
        let container = CKContainer(identifier: id)
        self.container = container
        let account = (try? await container.accountStatus()).map(Self.describe) ?? "unknown"
        log("Start. iCloud account: \(account). Waiting to send: \(pendingCount).")
        // A direct request, outside the sync engine, to tell "iCloud unreachable" from "engine stuck".
        Task { [container] in
            let started = Date()
            do {
                let zones = try await container.privateCloudDatabase.allRecordZones()
                await self.log("Reached iCloud in \(Int(Date().timeIntervalSince(started)))s: \(zones.count) folders (\(zones.map(\.zoneID.zoneName).joined(separator: ", "))).")
            } catch {
                await self.log("Couldn't reach iCloud directly after \(Int(Date().timeIntervalSince(started)))s: \(Self.describe(error))")
            }
        }
        let unreadable = await MainActor.run { sources.flatMap(\.unreadableFiles) }
        if !unreadable.isEmpty {
            // A local file couldn't be read: rebuild from iCloud rather than treat it as deleted.
            forgetEngineState()
            resetLocalSyncState()
        }
        // Once, on moving to sealed records: every earlier send was refused, so the sync engine's
        // saved state only holds a stuck queue (on one iPhone it made every fetch hang). Start
        // it afresh; the data on this device is untouched and record names are kept.
        let sealedFlag = stateFolder.appendingPathComponent("sync-sealed-reset")
        if !FileManager.default.fileExists(atPath: sealedFlag.path) {
            forgetEngineState()
            resetLocalSyncState()
            FileManager.default.createFile(atPath: sealedFlag.path, contents: Data())
            log("Started the sync engine afresh for sealed records.")
        }
        let saved = Self.load(CKSyncEngine.State.Serialization.self, stateFolder.appendingPathComponent("sync-engine.json"))
        let engine = CKSyncEngine(CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self))
        privateEngine = engine
        dropLegacyPending(engine)
        log("Engine ready. Waiting to send: \(engine.state.pendingRecordZoneChanges.count) items, \(engine.state.pendingDatabaseChanges.count) folder changes.")
        var zones: [CKSyncEngine.PendingDatabaseChange] = [.saveZone(CKRecordZone(zoneID: Self.privateZone))]
        if household.role != .member { zones.append(.saveZone(CKRecordZone(zoneID: Self.householdZone))) }
        engine.state.add(pendingDatabaseChanges: zones)
        if household.role == .member { startSharedEngine() }
        await publishHousehold()
        // Local items are queued first, so they go up even if fetching is slow or fails.
        await localDataChanged()
        await fetch()
        await removeLegacyZones(container.privateCloudDatabase)
    }

    /// Deletes the first version's plain-field zones if they exist (directly, so a zone that
    /// is already gone can't hold up the sync engine).
    private func removeLegacyZones(_ database: CKDatabase) async {
        guard let zones = try? await database.allRecordZones() else { return }
        let legacy = zones.map(\.zoneID).filter { Self.legacyZones.contains($0) }
        guard !legacy.isEmpty else { return }
        _ = try? await database.modifyRecordZones(saving: [], deleting: legacy)
    }

    #if DEBUG
    /// Testing only (launch a Debug build with `-WipeICloud`): deletes every Duo Budget folder
    /// in this iCloud account and forgets what was synced, so a sync test starts clean.
    /// The data on this device is untouched.
    static func wipeICloud(stateFolder: URL) async {
        guard let id = containerID else { print("[sync] No iCloud container"); return }
        let database = CKContainer(identifier: id).privateCloudDatabase
        do {
            let zones = try await database.allRecordZones().map(\.zoneID).filter { $0.zoneName != CKRecordZone.ID.defaultZoneName }
            _ = try await database.modifyRecordZones(saving: [], deleting: zones)
            print("[sync] Deleted iCloud folders: \(zones.map(\.zoneName).joined(separator: ", "))")
        } catch {
            print("[sync] Couldn't wipe iCloud: \(describe(error))")
        }
        for file in ["sync-engine.json", "sync-engine-shared.json", "sync-state.json", "sync-records.json", "sync-names.json", "sync-sealed-reset", "sync-log.txt"] {
            try? FileManager.default.removeItem(at: stateFolder.appendingPathComponent(file))
        }
        print("[sync] Forgot this device's sync records")
    }
    #endif

    /// Sends every item again from scratch: for when the person thinks something is missing.
    func sendEverythingAgain() async {
        resetLocalSyncState()
        await localDataChanged()
    }

    private func startSharedEngine() {
        guard let container, sharedEngine == nil else { return }
        let saved = Self.load(CKSyncEngine.State.Serialization.self, stateFolder.appendingPathComponent("sync-engine-shared.json"))
        sharedEngine = CKSyncEngine(CKSyncEngine.Configuration(database: container.sharedCloudDatabase, stateSerialization: saved, delegate: self))
    }

    private var pendingCount: Int {
        (privateEngine?.state.pendingRecordZoneChanges.count ?? 0) + (sharedEngine?.state.pendingRecordZoneChanges.count ?? 0)
    }

    private func report(_ text: String) async {
        guard let status else { return }
        let pending = pendingCount
        let held = heldDeletes.count
        let state: SyncStatus.State
        if held > 0 {
            state = .error("\(held) deletions are waiting for you in Settings › iCloud")
        } else if text.hasPrefix("Couldn't") {
            state = pending > 0 ? .pendingOffline : .error(text)
        } else if text.hasPrefix("Sign") {
            state = .error(text)
        } else {
            state = pending > 0 ? .pendingOffline : .upToDate
        }
        let failure = text.hasPrefix("Couldn't") || text.hasPrefix("Sign") ? text : nil
        await MainActor.run {
            status.update(text)
            status.set(state, pending: pending)
            status.setHeld(held)
            if let failure { status.noteError(failure) }
        }
    }

    private func reportSyncing() async {
        guard let status else { return }
        let pending = pendingCount
        await MainActor.run { status.set(.syncing, pending: pending) }
    }

    private func publishHousehold() async {
        guard let status else { return }
        let link = household
        await MainActor.run { status.household = link }
    }

    private func fetch() async {
        await reportSyncing()
        do {
            try await withTimeout(seconds: 60) { [privateEngine, sharedEngine] in
                try await privateEngine?.fetchChanges()
                try await sharedEngine?.fetchChanges()
            }
            await report("Up to date")
        } catch let error as CKError where error.code == .notAuthenticated {
            log("Fetch: not signed in to iCloud.")
            await report("Sign in to iCloud on this device to sync")
        } catch {
            log("Fetch failed: \(Self.describe(error))")
            await report("Couldn't reach iCloud: \(error.localizedDescription)")
        }
    }

    /// Runs work, giving up after a while so a stuck fetch can't block everything after it.
    private func withTimeout(seconds: Double, _ work: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CKError(.networkFailure)
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Call after local data is saved. Queues whatever changed since the last sync.
    func localDataChanged() async {
        guard privateEngine != nil else { return }
        guard await MainActor.run(body: { !sources.contains { $0.isWaitingForFiles } }) else { return }
        let current = await MainActor.run { sources.flatMap { $0.syncRecords() } }
        var changes = state.changes(to: current)
        // Many deletions at once usually mean something went wrong, not that the person meant it.
        let tooMany = changes.deletes.count > Self.largeDeletion
            || (state.entries.count >= 10 && changes.deletes.count * 5 > state.entries.count)
        if tooMany && !allowLargeDeletionOnce {
            heldDeletes = changes.deletes
            changes.deletes = []
        } else {
            heldDeletes = []
        }
        allowLargeDeletionOnce = false
        guard !changes.isEmpty else {
            await report(heldDeletes.isEmpty ? "Up to date" : "Held back \(heldDeletes.count) deletions")
            return
        }
        for delete in changes.deletes {
            if let name = recordName(for: delete.key) {
                engineFor(isPrivate: delete.isPrivate)?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(name, isPrivate: delete.isPrivate))])
            }
            state.recordDeleted(delete.key)
        }
        for record in changes.saves {
            let name = recordName(for: record.key) ?? UUID().uuidString
            names[record.key] = name
            outgoing[name] = record
            engineFor(isPrivate: record.isPrivate)?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(name, isPrivate: record.isPrivate))])
        }
        saveState()
        await reportSyncing()
        do {
            try await withTimeout(seconds: 120) { [privateEngine, sharedEngine] in
                try await privateEngine?.sendChanges()
                try await sharedEngine?.sendChanges()
            }
            if let refusal = lastRefusal {
                await report("Couldn't send \(refusal.count) item\(refusal.count == 1 ? "" : "s"): \(refusal.reason)")
            } else {
                await report("Sent \(changes.saves.count + changes.deletes.count) change\(changes.saves.count + changes.deletes.count == 1 ? "" : "s")")
            }
        } catch {
            log("Send failed: \(Self.describe(error))")
            await report("Couldn't send changes: \(error.localizedDescription)")
        }
    }

    /// The person confirmed the held deletions (or erased everything on purpose).
    func confirmLargeDeletion() async {
        allowLargeDeletionOnce = true
        await localDataChanged()
    }

    /// The person chose to bring back what was about to be deleted, from iCloud.
    func restoreFromCloud() async {
        heldDeletes = []
        forgetEngineState()
        resetLocalSyncState()
        privateEngine = nil
        sharedEngine = nil
        await start()
    }

    /// Fetches changes now, e.g. when the app comes to the front. Runs on its own, so the
    /// screen going away (the phone locking) doesn't cancel it halfway.
    func refresh() async {
        await Task { await self.fetch() }.value
    }

    // MARK: Household sharing

    /// The household share, created the first time. Only the owner (or a solo user) shares.
    func prepareShare() async throws -> CKShare {
        guard let container else { throw CKError(.notAuthenticated) }
        guard household.role != .member else { throw CKError(.permissionFailure) }
        let database = container.privateCloudDatabase
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.householdZone)
        if let existing = try? await database.record(for: shareID) as? CKShare {
            return existing
        }
        let share = CKShare(recordZoneID: Self.householdZone)
        share[CKShare.SystemFieldKey.title] = "Duo Budget household"
        share.publicPermission = .none
        let saved = try await database.save(share)
        household.role = .owner
        saveHousehold()
        await publishHousehold()
        guard let saved = saved as? CKShare else { throw CKError(.internalError) }
        return saved
    }

    /// Joins a partner's household from their invitation. Shared items on this device move into it.
    func accept(_ metadata: CKShare.Metadata) async throws {
        guard let container else { throw CKError(.notAuthenticated) }
        _ = try await container.accept(metadata)
        let zone = metadata.share.recordID.zoneID
        household = HouseholdLink(role: .member, zoneName: zone.zoneName, zoneOwner: zone.ownerName,
                                  sharedBy: metadata.ownerIdentity.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) } ?? "your partner")
        saveHousehold()
        // Everything shared is sent again, into the partner's household.
        resetLocalSyncState()
        privateEngine?.state.add(pendingDatabaseChanges: [.deleteZone(Self.householdZone)])
        startSharedEngine()
        await publishHousehold()
        await fetch()
        await localDataChanged()
    }

    /// Leaves a partner's household (member), or stops sharing it (owner). Data already on the
    /// other person's devices stays there: iCloud can't recall it.
    func leaveHousehold() async throws {
        guard let container else { return }
        switch household.role {
        case .member:
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: householdZoneID)
            _ = try? await container.sharedCloudDatabase.deleteRecord(withID: shareID)
            sharedEngine = nil
            try? FileManager.default.removeItem(at: stateFolder.appendingPathComponent("sync-engine-shared.json"))
        case .owner:
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.householdZone)
            _ = try await container.privateCloudDatabase.deleteRecord(withID: shareID)
        case .solo:
            return
        }
        household = HouseholdLink()
        saveHousehold()
        resetLocalSyncState()
        privateEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.householdZone))])
        await publishHousehold()
        await localDataChanged()
    }

    /// Who the household is shared with, for Settings (owner only).
    func refreshParticipants() async {
        guard let container, household.role == .owner, let status else { return }
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: Self.householdZone)
        guard let share = try? await container.privateCloudDatabase.record(for: shareID) as? CKShare else { return }
        let people = share.participants.filter { $0.role != .owner }.map { participant -> String in
            let identity = participant.userIdentity
            let name = identity.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) }
                ?? identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber ?? "Partner"
            switch participant.acceptanceStatus {
            case .accepted: return name
            case .pending: return "\(name) (invited)"
            default: return "\(name) (not joined)"
            }
        }
        await MainActor.run { status.participants = people }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let isShared = syncEngine === sharedEngine
        if case .stateUpdate = event {} else { log("Event: \(Self.name(of: event))\(isShared ? " (shared)" : "")") }
        switch event {
        case .stateUpdate(let update):
            Self.save(update.stateSerialization, stateFolder.appendingPathComponent(isShared ? "sync-engine-shared.json" : "sync-engine.json"))

        case .accountChange(let change):
            log("Account change: \(change.changeType).")
            if case .signOut = change.changeType { await report("Signed out of iCloud") }
            if case .switchAccounts = change.changeType { resetLocalSyncState() }
            if case .signOut = change.changeType { resetLocalSyncState() }

        case .fetchedRecordZoneChanges(let changes):
            await applyFetched(changes, syncEngine: syncEngine)

        case .sentRecordZoneChanges(let sent):
            log("Sent: \(sent.savedRecords.count) saved, \(sent.deletedRecordIDs.count) deleted, \(sent.failedRecordSaves.count) refused, \(sent.failedRecordDeletes.count) deletes refused.")
            var refused: [String: Int] = [:]
            for failure in sent.failedRecordSaves { refused[Self.describe(failure.error), default: 0] += 1 }
            for (reason, count) in refused { log("  \(count) refused: \(reason)") }
            let lasting = sent.failedRecordSaves.filter { ![.serverRecordChanged, .zoneNotFound, .unknownItem, .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy].contains($0.error.code) }
            lastRefusal = lasting.isEmpty ? nil : (lasting.count, lasting[0].error.localizedDescription)
            for record in sent.savedRecords {
                let name = record.recordID.recordName
                systemFields[name] = encodeSystemFields(record)
                if let item = outgoing.removeValue(forKey: name) { state.recordSaved(item) }
            }
            var retry: [CKSyncEngine.PendingRecordZoneChange] = []
            for failure in sent.failedRecordSaves {
                let name = failure.record.recordID.recordName
                switch failure.error.code {
                case .serverRecordChanged:
                    // Someone else saved it first: keep their change tag and send ours again.
                    if let server = failure.error.serverRecord { systemFields[name] = encodeSystemFields(server) }
                    retry.append(.saveRecord(failure.record.recordID))
                case .zoneNotFound:
                    if failure.record.recordID.zoneID == Self.privateZone || failure.record.recordID.zoneID == Self.householdZone {
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: failure.record.recordID.zoneID))])
                        retry.append(.saveRecord(failure.record.recordID))
                    }
                case .unknownItem:
                    systemFields[name] = nil
                    retry.append(.saveRecord(failure.record.recordID))
                default:
                    // Network or quota problems: CKSyncEngine retries on its own later.
                    break
                }
            }
            for id in sent.deletedRecordIDs { systemFields[id.recordName] = nil }
            if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            saveState()

        case .sentDatabaseChanges(let sent):
            if !sent.failedZoneSaves.isEmpty || !sent.failedZoneDeletes.isEmpty {
                for failure in sent.failedZoneSaves { log("Zone \(failure.zone.zoneID.zoneName) couldn't be created: \(Self.describe(failure.error))") }
                for (zone, error) in sent.failedZoneDeletes { log("Zone \(zone.zoneName) couldn't be deleted: \(Self.describe(error))") }
            } else if !sent.savedZones.isEmpty {
                log("Zones ready: \(sent.savedZones.map(\.zoneID.zoneName).joined(separator: ", ")).")
            }

        case .fetchedDatabaseChanges(let changes):
            if isShared, changes.deletions.contains(where: { $0.zoneID == householdZoneID }) {
                // The partner stopped sharing or removed this device's account. Data stays here.
                household = HouseholdLink()
                saveHousehold()
                sharedEngine = nil
                resetLocalSyncState()
                privateEngine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.householdZone))])
                await publishHousehold()
                await report("Your partner stopped sharing the household")
            } else if !isShared, changes.deletions.contains(where: { $0.zoneID == Self.householdZone || $0.zoneID == Self.privateZone }) {
                // A zone deleted on another device: forget what was sent and send it again.
                resetLocalSyncState()
            }

        default:
            break
        }
    }

    private func applyFetched(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, syncEngine: CKSyncEngine) async {
        var saves: [SyncRecord] = []
        var fetchedRecords: [(CKRecord, SyncRecord)] = []
        var duplicateDeletes: [CKRecord.ID] = []
        for modification in changes.modifications {
            let record = modification.record
            guard var item = syncRecord(from: record) else { continue }
            let name = record.recordID.recordName
            // Two devices created the same item before syncing: keep the record with the smaller
            // name everywhere (both sides decide alike) and delete the other.
            if let known = recordName(for: item.key), known != name {
                let keep = min(known, name)
                let drop = keep == name ? known : name
                duplicateDeletes.append(CKRecord.ID(recordName: drop, zoneID: record.recordID.zoneID))
                names[item.key] = keep
                if keep != name { continue }
            }
            names[item.key] = name
            item.byPartner = record.lastModifiedUserRecordID.map { $0.recordName != CKCurrentUserDefaultName } ?? false
            fetchedRecords.append((record, item))
            saves.append(item)
        }
        var deletes = Set<String>()
        let keysByName = Dictionary(names.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for deletion in changes.deletions {
            let name = deletion.recordID.recordName
            systemFields[name] = nil
            let legacyKey = keysByName[name] == nil ? state.entries.keys.first { Self.legacyRecordName($0) == name } : nil
            guard let key = keysByName[name] ?? legacyKey, (names[key] ?? Self.legacyRecordName(key)) == name else { continue }
            // Moving between zones deletes from one and saves in the other: keep the save.
            guard !saves.contains(where: { $0.key == key }) else { continue }
            deletes.insert(key)
        }
        if !duplicateDeletes.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: duplicateDeletes.map { .deleteRecord($0) }) }
        guard !saves.isEmpty || !deletes.isEmpty else { saveState(); return }
        let finalSaves = saves, finalDeletes = deletes
        let rejected = await MainActor.run { () -> (saved: Bool, rejected: Set<String>) in
            var ok = true
            var rejected = Set<String>()
            for source in sources {
                let result = source.applySync(saves: finalSaves, deletes: finalDeletes)
                ok = ok && result
                rejected.formUnion(source.rejectedKeys(finalSaves))
            }
            return (ok, rejected)
        }
        // Only mark changes as synced once they're on disk; otherwise they're fetched again.
        guard rejected.saved else { await report("Couldn't save changes from iCloud yet"); return }
        for (record, item) in fetchedRecords {
            systemFields[record.recordID.recordName] = encodeSystemFields(record)
            if rejected.rejected.contains(item.key) {
                // Not the partner's to change: our version is sent back.
                state.recordDeleted(item.key)
            } else {
                state.recordSaved(item)
            }
        }
        for key in deletes { state.recordDeleted(key) }
        saveState()
        await report("Received \(saves.count + deletes.count) change\(saves.count + deletes.count == 1 ? "" : "s")")
        if !rejected.rejected.isEmpty { await localDataChanged() }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        var pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // A save this device can no longer build (its item is gone, or it's left over from an
        // older version) would sit in the queue for ever: drop it instead.
        let orphans = pending.filter { if case .saveRecord(let id) = $0 { outgoing[id.recordName] == nil } else { false } }
        if !orphans.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: orphans)
            pending.removeAll { orphans.contains($0) }
            log("Dropped \(orphans.count) queued saves with nothing to send.")
        }
        // A receipt photo that can't be read right now (the phone locked since it was saved)
        // waits for the next send, rather than going up without its picture.
        let waiting = pending.filter { change in
            guard case .saveRecord(let id) = change, let name = outgoing[id.recordName]?.fileName else { return false }
            return Self.imageForUpload(imagesFolder.appendingPathComponent(name)) == nil
                && FileManager.default.fileExists(atPath: imagesFolder.appendingPathComponent(name).path)
        }
        pending.removeAll { waiting.contains($0) }
        if !waiting.isEmpty { log("\(waiting.count) receipt photos wait until they can be read.") }
        log("Sending a batch of \(pending.count) (reason: \(context.reason)).")
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await self.ckRecord(for: recordID)
        }
    }

    // MARK: Records

    /// The record name an item already has. Items first sent by the previous version were
    /// named by a hash of their key; those keep that name, so they're updated and deleted
    /// in place instead of being duplicated.
    private func recordName(for key: String) -> String? {
        if let name = names[key] { return name }
        guard state.entries[key] != nil else { return nil }
        let legacy = Self.legacyRecordName(key)
        names[key] = legacy
        return legacy
    }

    static func legacyRecordName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func engineFor(isPrivate: Bool) -> CKSyncEngine? {
        (!isPrivate && household.role == .member) ? sharedEngine : privateEngine
    }

    private func recordID(_ name: String, isPrivate: Bool) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: isPrivate ? Self.privateZone : householdZoneID)
    }

    private func ckRecord(for id: CKRecord.ID) -> CKRecord? {
        guard let item = outgoing[id.recordName] else { return nil }
        var record = CKRecord(recordType: Self.recordType, recordID: id)
        if let fields = systemFields[id.recordName], let saved = decodeSystemFields(fields), saved.recordID.zoneID == id.zoneID {
            record = saved
        }
        // All in encrypted fields: end-to-end encrypted, unreadable to anyone but the owner
        // and the people they share the household with.
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
        if let data = record.encryptedValues["file"] as? Data,
           let name = record.encryptedValues["fileName"] as? String, Self.isSafeImageName(name) {
            try? data.write(to: imagesFolder.appendingPathComponent(name), options: JSONFileStorage.writeOptions)
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

    /// Photo names from iCloud must look like the app's own ("<UUID>.jpg"), so a record can't
    /// overwrite some other file.
    static func isSafeImageName(_ name: String) -> Bool {
        name.range(of: "^[0-9A-Fa-f-]{36}\\.(jpg|jpeg|png|heic|heif|tif|tiff)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A receipt photo for an encrypted field: re-encoded without metadata (no location or
    /// camera details), shrunk until it fits under `maxImageBytes`. Nil when the file is missing.
    static func imageForUpload(_ url: URL) -> Data? {
        guard let original = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(original as CFData, nil) else { return nil }
        for (side, quality) in [(2400, 0.75), (2000, 0.7), (1600, 0.6), (1200, 0.5), (900, 0.45)] {
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

    /// The first version named records after their keys, in zones that no longer exist. Any of
    /// those still queued (and the queued deletion of those zones, done directly instead) are
    /// dropped, so they can't stall the queue.
    private func dropLegacyPending(_ engine: CKSyncEngine) {
        let legacyRecords = engine.state.pendingRecordZoneChanges.filter { change in
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): Self.legacyZones.contains(id.zoneID)
            @unknown default: false
            }
        }
        let legacyZones = engine.state.pendingDatabaseChanges.filter { change in
            switch change {
            case .saveZone(let zone): Self.legacyZones.contains(zone.zoneID)
            case .deleteZone(let id): Self.legacyZones.contains(id)
            @unknown default: false
            }
        }
        if !legacyRecords.isEmpty { engine.state.remove(pendingRecordZoneChanges: legacyRecords) }
        if !legacyZones.isEmpty { engine.state.remove(pendingDatabaseChanges: legacyZones) }
        if !legacyRecords.isEmpty || !legacyZones.isEmpty {
            log("Removed \(legacyRecords.count) old-version items and \(legacyZones.count) old folder changes from the queue.")
        }
    }

    static func name(of event: CKSyncEngine.Event) -> String {
        switch event {
        case .stateUpdate: "state update"
        case .accountChange: "account change"
        case .fetchedDatabaseChanges(let changes): "fetched folder changes (\(changes.modifications.count) changed, \(changes.deletions.count) deleted)"
        case .fetchedRecordZoneChanges(let changes): "fetched \(changes.modifications.count) items, \(changes.deletions.count) deletions"
        case .sentDatabaseChanges(let sent): "sent folder changes (\(sent.savedZones.count) saved, \(sent.failedZoneSaves.count) failed)"
        case .sentRecordZoneChanges(let sent): "sent items (\(sent.savedRecords.count) saved, \(sent.failedRecordSaves.count) failed)"
        case .willFetchChanges: "will fetch"
        case .willFetchRecordZoneChanges(let zone): "will fetch \(zone.zoneID.zoneName)"
        case .didFetchRecordZoneChanges(let zone): "did fetch \(zone.zoneID.zoneName)\(zone.error.map { ": \(describe($0))" } ?? "")"
        case .didFetchChanges: "did fetch"
        case .willSendChanges: "will send"
        case .didSendChanges: "did send"
        @unknown default: "other"
        }
    }

    // MARK: Sync log

    /// The last refusals from iCloud that retrying won't fix, for the status line.
    private var lastRefusal: (count: Int, reason: String)?

    /// A short, plain log of what sync did, kept on this device only (sync-log.txt, last 300
    /// lines), so a sync that silently stalls can be diagnosed. It holds no item contents.
    private func log(_ line: String) {
        let url = stateFolder.appendingPathComponent("sync-log.txt")
        try? FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601)
        print("[sync] \(line)")
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        lines.append("\(stamp) \(line)")
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        return "CKError \(error.code.rawValue) (\(error.code)) \(error.localizedDescription)"
    }

    static func describe(_ status: CKAccountStatus) -> String {
        switch status {
        case .available: "available"
        case .noAccount: "no account"
        case .restricted: "restricted"
        case .couldNotDetermine: "could not determine"
        case .temporarilyUnavailable: "temporarily unavailable"
        @unknown default: "unknown"
        }
    }

    // MARK: Saved state

    /// Everything is compared and sent again from scratch (after an account change, joining or
    /// leaving a household, or a restore). Record names are kept so nothing is duplicated.
    private func resetLocalSyncState() {
        state = SyncState()
        systemFields = [:]
        outgoing = [:]
        saveState()
    }

    /// Makes the next start fetch everything from iCloud again.
    private func forgetEngineState() {
        for file in ["sync-engine.json", "sync-engine-shared.json"] {
            try? FileManager.default.removeItem(at: stateFolder.appendingPathComponent(file))
        }
    }

    private func saveState() {
        Self.save(state, stateFolder.appendingPathComponent("sync-state.json"))
        Self.save(systemFields, stateFolder.appendingPathComponent("sync-records.json"))
        Self.save(names, stateFolder.appendingPathComponent("sync-names.json"))
    }

    private func saveHousehold() {
        Self.save(household, stateFolder.appendingPathComponent("household.json"))
    }

    private static func load<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Sync bookkeeping holds dates and merchants, so it gets the same protection as the data.
    private static func save<T: Encodable>(_ value: T, _ url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: JSONFileStorage.writeOptions)
    }
}
