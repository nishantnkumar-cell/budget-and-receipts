import BudgetCore
import CloudKit
import Foundation

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
actor CloudSync: CKSyncEngineDelegate {
    static let householdZone = CKRecordZone.ID(zoneName: "Household")
    static let privateZone = CKRecordZone.ID(zoneName: "Private")

    /// The iCloud container, read from Info.plist. Nil in builds without iCloud (tests, unsigned).
    nonisolated static var containerID: String? {
        Bundle.main.object(forInfoDictionaryKey: "CloudKitContainer") as? String
    }

    private let sources: [SyncSource]
    private let imagesFolder: URL
    private let stateFolder: URL
    private var engine: CKSyncEngine?
    private var state: SyncState
    /// iCloud's bookkeeping for each record (its change tag), so saves don't conflict.
    private var systemFields: [String: Data]
    /// Records waiting to be sent, by iCloud record name.
    private var outgoing: [String: SyncRecord] = [:]

    init(sources: [SyncSource], imagesFolder: URL, stateFolder: URL) {
        self.sources = sources
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
        if saved == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.householdZone)), .saveZone(CKRecordZone(zoneID: Self.privateZone))])
        }
        try? await engine.fetchChanges()
        await localDataChanged()
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
            outgoing[record.key] = record
            pending.append(.saveRecord(recordID(record.key, isPrivate: record.isPrivate)))
        }
        engine.state.add(pendingRecordZoneChanges: pending)
        saveState()
        try? await engine.sendChanges()
    }

    /// Fetches changes now, e.g. when the app comes to the front.
    func refresh() async {
        try? await engine?.fetchChanges()
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Self.save(update.stateSerialization, stateFolder.appendingPathComponent("sync-engine.json"))

        case .accountChange(let change):
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
                let key = deletion.recordID.recordName
                // Moving between zones deletes from one and saves in the other: keep the save.
                guard !saves.contains(where: { $0.key == key }) else { continue }
                deletes.insert(key)
                state.recordDeleted(key)
                systemFields[key] = nil
            }
            saveState()
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
        CKRecord.ID(recordName: key, zoneID: isPrivate ? Self.privateZone : Self.householdZone)
    }

    private func ckRecord(for id: CKRecord.ID) -> CKRecord? {
        guard let item = outgoing[id.recordName] else { return nil }
        var record = CKRecord(recordType: "Item", recordID: id)
        if let fields = systemFields[id.recordName], let saved = decodeSystemFields(fields), saved.recordID.zoneID == id.zoneID {
            record = saved
        }
        record["collection"] = item.collection
        record["itemID"] = item.id
        record["payload"] = item.payload
        record["modifiedAt"] = Date()
        if let name = item.fileName {
            record["file"] = CKAsset(fileURL: imagesFolder.appendingPathComponent(name))
        }
        return record
    }

    private func syncRecord(from record: CKRecord) -> SyncRecord? {
        guard let collection = record["collection"] as? String, let id = record["itemID"] as? String else { return nil }
        var fileName: String?
        if let asset = record["file"] as? CKAsset, let url = asset.fileURL {
            let name = (id as NSString).lastPathComponent
            let destination = imagesFolder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.copyItem(at: url, to: destination)
            fileName = name
        }
        return SyncRecord(
            collection: collection,
            id: id,
            payload: record["payload"] as? Data ?? Data(),
            isPrivate: record.recordID.zoneID == Self.privateZone,
            fileName: fileName
        )
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
