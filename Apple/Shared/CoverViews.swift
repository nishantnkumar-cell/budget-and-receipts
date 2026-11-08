import BudgetCore
import SwiftUI

// Return-by dates and warranties on receipts, with reminders (the same ones contracts use).

/// Plan's list of things that can still go back, or are under warranty.
struct ReturnsWarrantiesSection: View {
    @EnvironmentObject var store: BudgetStore
    @State private var deleting: ProductCover?
    @State private var showingAll = false

    var body: some View {
        let active = CoverWatch().active(store.covers)
        Section {
            ForEach(active.prefix(5)) { cover in
                DeletableRow(onDelete: { deleting = cover }) {
                    NavigationLink { ProductCoverEditor(cover: cover) } label: { ProductCoverRow(cover: cover) }
                }
            }
            if store.covers.count > min(active.count, 5) {
                NavigationLink("All \(store.covers.count) Returns and Warranties") { ProductCoversList() }
            }
            NavigationLink { ProductCoverEditor(cover: ProductCover(item: "", shop: "", purchased: Date())) } label: {
                Label("Add Return or Warranty", systemImage: "plus")
            }
        } header: {
            Label("Returns and warranties", systemImage: "shield.lefthalf.filled")
        } footer: {
            Text("Reminders come 3 days before the last day to return something, and 30 days before a warranty ends. Add them from a receipt to keep its photo.")
        }
        .alert("Delete \(deleting?.item ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let deleting { store.deleteCover(deleting) }
                deleting = nil
            }
        } message: {
            Text("Its reminders stop. The payment and receipt stay.")
        }
    }
}

struct ProductCoversList: View {
    @EnvironmentObject var store: BudgetStore

    var body: some View {
        List {
            ForEach(store.covers.sorted { $0.purchased > $1.purchased }) { cover in
                DeletableRow(onDelete: { store.deleteCover(cover) }) {
                    NavigationLink { ProductCoverEditor(cover: cover) } label: { ProductCoverRow(cover: cover) }
                }
            }
        }
        .navigationTitle("Returns and warranties")
    }
}

struct ProductCoverRow: View {
    let cover: ProductCover

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: cover.warrantyEnds != nil ? "shield.lefthalf.filled" : "arrow.uturn.backward", tint: .brandTeal)
            VStack(alignment: .leading, spacing: 3) {
                Text(cover.item.isEmpty ? cover.shop : cover.item).font(.body.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let urgency = CoverWatch().urgency(cover) { CoverUrgencyChip(urgency: urgency) }
            }
            Spacer()
            if let price = cover.price { Text(price.money).monospacedDigit() }
        }
    }

    private var detail: String {
        var parts = [cover.shop, cover.purchased.formatted(.dateTime.day().month(.abbreviated).year())].filter { !$0.isEmpty }
        if cover.returned == true { parts.append("returned") }
        else if let returnBy = cover.returnBy, returnBy >= Calendar.current.startOfDay(for: Date()) { parts.append("return by \(returnBy.formatted(.dateTime.day().month(.abbreviated)))") }
        if let ends = cover.warrantyEnds { parts.append("warranty to \(ends.formatted(.dateTime.month(.abbreviated).year()))") }
        return parts.joined(separator: " · ")
    }
}

/// Red when a return closes in 3 days or less, amber otherwise (as contracts are shown).
struct CoverUrgencyChip: View {
    let urgency: CoverUrgency

    var body: some View {
        let color: Color = urgency.isUrgent ? .red : .brandAmber
        Label(text, systemImage: urgency.isUrgent ? "exclamationmark.circle.fill" : "clock")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var text: String {
        let when = urgency.days == 0 ? "today" : urgency.days == 1 ? "tomorrow" : "in \(urgency.days) days"
        switch urgency {
        case .returnBy: return "Last day to return \(when)"
        case .warrantyEnds: return "Warranty ends \(when)"
        }
    }
}

/// Add or change a return window or warranty.
struct ProductCoverEditor: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State var cover: ProductCover

    private var isNew: Bool { !store.covers.contains { $0.id == cover.id } }

    var body: some View {
        Form {
            Section {
                TextField("Item", text: $cover.item, prompt: Text("e.g. Headphones"))
                TextField("Shop", text: $cover.shop)
                DatePicker("Bought", selection: $cover.purchased, displayedComponents: .date)
                TextField("Price (optional)", value: $cover.price, format: .number).decimalKeyboard()
            }
            Section {
                OptionalDatePicker(title: "Return by", date: $cover.returnBy)
                if cover.returnBy == nil {
                    quickPicks(ProductCover.returnWindows.map { ("\($0) days", Calendar.current.date(byAdding: .day, value: $0, to: cover.purchased)) }) { cover.returnBy = $0 }
                }
                if cover.returnBy != nil {
                    Toggle("Returned", isOn: Binding(get: { cover.returned == true }, set: { cover.returned = $0 ? true : nil }))
                }
            } header: {
                Text("Return")
            }
            Section {
                OptionalDatePicker(title: "Warranty ends", date: $cover.warrantyEnds)
                if cover.warrantyEnds == nil {
                    quickPicks(ProductCover.warrantyYears.map { ("\($0) year\($0 == 1 ? "" : "s")", Calendar.current.date(byAdding: .year, value: $0, to: cover.purchased)) }) { cover.warrantyEnds = $0 }
                }
            } header: {
                Text("Warranty")
            }
            Section {
                TextField("Note", text: Binding(get: { cover.note ?? "" }, set: { cover.note = $0.isEmpty ? nil : $0 }), prompt: Text("e.g. serial number"), axis: .vertical)
                if let image = cover.receiptImage, !image.isEmpty {
                    ReceiptImagePreview(imagePath: image)
                }
                PrivateToggle(isPrivate: $cover.isPrivate)
            }
            if !isNew {
                DeleteSection(title: "Delete", message: "Its reminders stop. The payment and receipt stay.") {
                    store.deleteCover(cover)
                    dismiss()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "Return or warranty" : (cover.item.isEmpty ? cover.shop : cover.item))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    store.saveCover(cover)
                    dismiss()
                }
                .disabled((cover.item + cover.shop).trimmingCharacters(in: .whitespaces).isEmpty || (cover.returnBy == nil && cover.warrantyEnds == nil))
            }
        }
    }

    private func quickPicks(_ options: [(String, Date?)], pick: @escaping (Date) -> Void) -> some View {
        HStack {
            ForEach(options, id: \.0) { option in
                Button(option.0) { if let date = option.1 { pick(date) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

/// On a receipt or payment: its return and warranty dates, and a way to add them.
struct ReceiptCoverSection: View {
    @EnvironmentObject var store: BudgetStore
    let transactionID: String?
    var shop: String
    var date: Date
    var item: String = ""
    var price: Decimal?
    var imagePath: String = ""

    var body: some View {
        let covers = store.covers.filter { $0.transactionID != nil && $0.transactionID == transactionID }
        Section {
            ForEach(covers) { cover in
                NavigationLink { ProductCoverEditor(cover: cover) } label: { ProductCoverRow(cover: cover) }
            }
            NavigationLink {
                ProductCoverEditor(cover: ProductCover(item: item, shop: shop, purchased: date, price: price, transactionID: transactionID,
                                                       receiptImage: imagePath.isEmpty ? nil : (imagePath as NSString).lastPathComponent))
            } label: {
                Label("Add Return or Warranty Date", systemImage: "shield.lefthalf.filled")
            }
        } header: {
            Text("Returns and warranty")
        } footer: {
            Text("Get reminded before the last day to return it or before its warranty runs out. The receipt photo is kept with it.")
        }
    }
}

/// What the reminders depend on, so they're rescheduled when contracts or receipt dates change.
struct ReminderInputs: Equatable {
    let contracts: [SubscriptionContract]
    let covers: [ProductCover]
}
