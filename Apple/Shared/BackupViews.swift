import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A Duo Budget encrypted backup (.duobackup).
    static let duoBackup = UTType(exportedAs: "com.nishantkumar.budgetreceipts.backup", conformingTo: .data)
}

/// Settings › Backup: export a password-protected backup, or restore one.
struct BackupSection: View {
    var body: some View {
        Section {
            NavigationLink { ExportBackupView() } label: { Label("Export Encrypted Backup…", systemImage: "lock.doc") }
            NavigationLink { RestoreBackupView() } label: { Label("Restore From Backup…", systemImage: "clock.arrow.circlepath") }
        } header: {
            Text("Backup")
        } footer: {
            Text("A single file with everything, locked with a password you choose. Keep it somewhere safe, like Files or a USB drive. Without the password nobody can open it, including you, so don't lose it.")
        }
    }
}

struct ExportBackupView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var password = ""
    @State private var confirmation = ""
    @State private var file: ExportDocument?
    @State private var working = false
    @State private var message: String?

    private var problem: String? {
        if password.count < EncryptedBackup.minimumPasswordLength { return "At least \(EncryptedBackup.minimumPasswordLength) characters." }
        if password != confirmation { return "The two passwords don't match yet." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                SecureField("Password", text: $password).textContentType(.newPassword)
                SecureField("Type it again", text: $confirmation).textContentType(.newPassword)
            } footer: {
                Text(problem ?? "The password can't be recovered. Write it down or keep it in your password manager.")
            }
            Section {
                Button {
                    export()
                } label: {
                    if working { ProgressView() } else { Label("Export Backup", systemImage: "square.and.arrow.up") }
                }
                .disabled(problem != nil || working)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Includes payments, budgets, goals, contracts, rules, receipt photos and contract documents. Settings on this device and the iCloud connection aren't included.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Export backup")
        .fileExporter(isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } }), document: file, contentType: .duoBackup,
                      defaultFilename: "Duo Budget \(Date().formatted(.iso8601.year().month().day())).\(EncryptedBackup.fileExtension)") { result in
            switch result {
            case .success: message = "Backup saved. Keep the password safe."
            case .failure(let error): message = "Couldn't save it: \(error.localizedDescription)"
            }
            password = ""
            confirmation = ""
        }
    }

    private func export() {
        working = true
        let folder = store.dataFolder
        let password = password
        let device = Self.deviceName
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        Task {
            let result = await Task.detached { Result { try EncryptedBackup.make(folder: folder, password: password, device: device, appVersion: version) } }.value
            working = false
            switch result {
            case .success(let data): file = ExportDocument(data: data, type: .duoBackup)
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    static var deviceName: String {
        #if os(iOS)
        "iPhone"
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}

struct RestoreBackupView: View {
    @EnvironmentObject var store: BudgetStore
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var fileData: Data?
    @State private var fileName = ""
    @State private var password = ""
    @State private var contents: EncryptedBackup.Contents?
    @State private var working = false
    @State private var message: String?
    @State private var confirming = false

    private var here: String {
        #if os(iOS)
        "this iPhone"
        #else
        "this Mac"
        #endif
    }

    var body: some View {
        Form {
            Section {
                Button { choosing = true } label: { Label(fileData == nil ? "Choose Backup File" : fileName, systemImage: "doc") }
                if fileData != nil, contents == nil {
                    SecureField("Backup password", text: $password).onSubmit(unlock)
                    Button("Open Backup", action: unlock).disabled(password.isEmpty || working)
                }
                if let message { Text(message).font(.caption).foregroundStyle(Color.brandPink) }
            } footer: {
                Text("Opening a backup changes nothing. You'll see what's in it first.")
            }
            if let contents {
                Section {
                    LabeledContent("Made", value: contents.manifest.created.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("On", value: contents.manifest.device)
                    LabeledContent("Payments", value: "\(contents.transactionCount)")
                    LabeledContent("Budgets", value: "\(contents.budgetCount)")
                    LabeledContent("Subscriptions and contracts", value: "\(contents.contractCount)")
                    LabeledContent("Receipt photos and documents", value: "\(contents.photoCount)")
                } header: {
                    Text("In this backup")
                } footer: {
                    Text("Now on \(here): \(store.transactions.count) payments, \(subscriptions.contracts.count) subscriptions and contracts.")
                }
                Section {
                    Button(role: .destructive) { confirming = true } label: {
                        Label("Replace Everything With This Backup…", systemImage: "exclamationmark.triangle")
                    }
                    .disabled(working)
                } footer: {
                    Text("Everything on \(here) is replaced by the backup, and iCloud sync then makes your other devices (and a partner you share with) match it. Payments added since the backup was made are lost. Export a backup of what's here now first if you might want it.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Restore backup")
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.duoBackup, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            fileData = try? Data(contentsOf: url)
            fileName = url.lastPathComponent
            contents = nil
            message = fileData == nil ? "Couldn't read that file." : nil
        }
        .confirmationDialog("Replace all data on \(here)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Replace With Backup From \(contents?.manifest.created.formatted(date: .abbreviated, time: .omitted) ?? "")", role: .destructive, action: restore)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. You'll be asked for \(AppLock().methodName) first.")
        }
    }

    private func unlock() {
        guard let fileData else { return }
        working = true
        let password = password
        Task {
            let result = await Task.detached { Result { try EncryptedBackup.open(fileData, password: password) } }.value
            working = false
            switch result {
            case .success(let opened): contents = opened; message = nil
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    private func restore() {
        guard let contents else { return }
        Task {
            let context = LAContext()
            if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Replace your data with the backup")) == true else { return }
            }
            working = true
            do {
                try store.restore(contents, subscriptions: subscriptions)
                message = nil
                self.contents = nil
                fileData = nil
                password = ""
                store.status = "Restored the backup from \(contents.manifest.created.formatted(date: .abbreviated, time: .omitted))."
                dismiss()
            } catch {
                message = "Nothing was changed: \(error.localizedDescription)"
            }
            working = false
        }
    }
}
