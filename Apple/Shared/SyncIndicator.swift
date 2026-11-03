import SwiftUI

extension SyncStatus.State {
    var title: String {
        switch self {
        case .off: "iCloud sync is off"
        case .syncing: "Syncing…"
        case .upToDate: "Up to date"
        case .pendingOffline: "Waiting to sync"
        case .error: "Sync needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .off, .pendingOffline: "icloud.slash"
        case .syncing: "arrow.triangle.2.circlepath.icloud"
        case .upToDate: "checkmark.icloud"
        case .error: "exclamationmark.icloud"
        }
    }

    /// Quiet grey when all is well, amber when changes are waiting, red when something's wrong.
    var color: Color {
        switch self {
        case .off, .syncing, .upToDate: .secondary
        case .pendingOffline: .orange
        case .error: .red
        }
    }
}

/// A small cloud that shows whether everything is synced: iPhone Home's top bar and the Mac
/// toolbar. Tapping it shows when it last synced and what's waiting. Hidden when sync is off.
struct SyncStatusButton: View {
    @EnvironmentObject var syncStatus: SyncStatus
    @State private var showingDetails = false

    var body: some View {
        if syncStatus.state != .off {
            Button { showingDetails = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: syncStatus.state.systemImage)
                        .symbolEffect(.rotate, isActive: syncStatus.state == .syncing)
                        .contentTransition(.symbolEffect(.replace))
                    if syncStatus.state == .pendingOffline, syncStatus.pendingCount > 0 {
                        Text("\(syncStatus.pendingCount)").font(.caption.monospacedDigit())
                    }
                }
                .foregroundStyle(syncStatus.state.color)
            }
            .accessibilityLabel(syncStatus.state.title)
            .help(syncStatus.state.title)
            #if os(iOS)
            .sheet(isPresented: $showingDetails) {
                SyncDetailsView().presentationDetents([.height(360)])
            }
            #else
            .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                SyncDetailsView().frame(width: 320)
            }
            #endif
        }
    }
}

/// When it last synced, what's waiting and what went wrong.
struct SyncDetailsView: View {
    @EnvironmentObject var syncStatus: SyncStatus

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: syncStatus.state.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(syncStatus.state == .upToDate ? Color.green : syncStatus.state.color)
            Text(syncStatus.state.title).font(.headline)
            VStack(spacing: 6) {
                if let lastSynced = syncStatus.lastSynced {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Last synced \(lastSynced, format: .relative(presentation: .named))")
                    }
                } else {
                    Text("Not synced yet")
                }
                SyncProgressBar()
                if syncStatus.pendingCount > 0, syncStatus.progress == nil {
                    Text("^[\(syncStatus.pendingCount) change](inflect: true) waiting to go to iCloud.")
                }
                SyncErrorLine()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Text("Your budget, receipts and contracts stay the same on your iPhone and Mac, end-to-end encrypted in your own iCloud.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// "Sending 12 of 68" with a bar, while changes are going up to iCloud.
struct SyncProgressBar: View {
    @EnvironmentObject var syncStatus: SyncStatus

    var body: some View {
        if let progress = syncStatus.progress {
            let sent = syncStatus.uploadTotal - syncStatus.pendingCount
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress).tint(.brandPink)
                Text("Sent \(sent) of \(syncStatus.uploadTotal) to iCloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The last problem, in red, until a sync succeeds.
struct SyncErrorLine: View {
    @EnvironmentObject var syncStatus: SyncStatus

    var body: some View {
        if let error = syncStatus.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
        }
    }
}
