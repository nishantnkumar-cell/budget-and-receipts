import SwiftUI

/// A list or form row that can be deleted the same way everywhere: swipe left on the iPhone,
/// right-click (or long-press) for Delete, and on the Mac a trash button at the end of the row,
/// because Mac forms have no swipe.
struct DeletableRow<Content: View>: View {
    var label = "Delete"
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            content()
            #if os(macOS)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
            #endif
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) { Label(label, systemImage: "trash") }
        }
        .contextMenu {
            Button(role: .destructive, action: onDelete) { Label(label, systemImage: "trash") }
        }
    }
}

/// The delete button at the bottom of an editor, with a confirmation first.
struct DeleteSection: View {
    let title: String
    let message: String
    let onDelete: () -> Void
    @State private var confirming = false

    var body: some View {
        Section {
            Button(role: .destructive) { confirming = true } label: {
                Label(title, systemImage: "trash")
            }
        }
        .alert("\(title)?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            Text(message)
        }
    }
}
