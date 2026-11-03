import BudgetCore
import SwiftUI

/// Settings › Categories: rename, recolour and re-icon categories, add your own, delete one
/// (its payments, budgets and rules move to another), and edit sub-categories.
struct CategoriesView: View {
    @EnvironmentObject var store: BudgetStore
    @State private var editing: CategoryDefinition?
    @State private var adding = false
    @State private var confirmingRestore = false

    var body: some View {
        let catalog = store.catalog
        let spending = catalog.visible.filter { !catalog.isLocked($0) }
        let locked = catalog.visible.filter { catalog.isLocked($0) }
        List {
            Section {
                ForEach(spending) { definition in
                    CategoryRow(definition: definition, isLocked: false) { editing = definition }
                }
                Button { adding = true } label: { Label("Add Category", systemImage: "plus") }
            } header: {
                Text("Spending")
            } footer: {
                Text("Tap a category to rename it, change its icon or colour, edit its sub-categories or delete it. Payments, budgets and rules follow every change.")
            }
            Section {
                ForEach(locked) { definition in
                    CategoryRow(definition: definition, isLocked: true) { editing = definition }
                }
            } header: {
                Text("Money in and transfers")
            } footer: {
                Text("The app's money rules use these names, so they stay. You can still change their icon, colour and sub-categories.")
            }
            if !store.categories.isEmpty {
                Section {
                    Button("Restore Built-in Categories", role: .destructive) { confirmingRestore = true }
                } footer: {
                    Text("Built-in categories get their names, icons and colours back. Your own categories are kept.")
                }
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add Category", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { definition in
            NavigationStack { CategoryEditor(id: definition.id) }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 600)
                #endif
        }
        .sheet(isPresented: $adding) {
            NavigationStack { NewCategoryView() }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 520)
                #endif
        }
        .confirmationDialog("Restore built-in categories?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore", role: .destructive) { store.editCategories { $0.restoreBuiltIn() } }
        } message: {
            Text("Renamed categories get their names back and their payments follow. Deleted ones come back empty: payments already moved stay where they are.")
        }
    }
}

struct CategoryRow: View {
    @EnvironmentObject var store: BudgetStore
    let definition: CategoryDefinition
    let isLocked: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                IconBadge(systemImage: definition.symbol, tint: definition.color.swatch, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.name)
                    let count = definition.subcategories.count
                    if count > 0 {
                        Text("\(count) sub-categor\(count == 1 ? "y" : "ies")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isLocked {
                    Image(systemName: "lock").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Name can't change")
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Editing one category

struct CategoryEditor: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let id: String

    @State private var name = ""
    @State private var symbol = ""
    @State private var color = CategoryColor.violet
    @State private var loaded = false
    @State private var error: String?

    @State private var addingSubcategory = false
    @State private var renamingSubcategory: String?
    @State private var subcategoryName = ""
    @State private var deletingSubcategory: String?

    @State private var moveTo = "Uncategorised"
    @State private var confirmingDelete = false

    var body: some View {
        let catalog = store.catalog
        if let definition = catalog.definition(id: id), !definition.deleted {
            form(definition, catalog: catalog)
        } else {
            ContentUnavailableView("Category deleted", systemImage: "trash")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func form(_ definition: CategoryDefinition, catalog: CategoryCatalog) -> some View {
        let isLocked = catalog.isLocked(definition)
        return Form {
            Section {
                TextField("Name", text: $name)
                    .disabled(isLocked)
                if let error { Text(error).font(.caption).foregroundStyle(Color.brandPink) }
            } header: {
                Text("Name")
            } footer: {
                if isLocked { Text("The app's money rules use this name, so it stays.") }
            }
            CategoryLookFields(symbol: $symbol, color: $color)
            Section {
                ForEach(definition.subcategories, id: \.self) { sub in
                    Button {
                        subcategoryName = sub
                        renamingSubcategory = sub
                    } label: {
                        LabeledContent(sub) {
                            let count = store.paymentCount(in: definition.name, subcategory: sub)
                            if count > 0 { Text("\(count)").foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLocked && CategoryCatalog.lockedSubcategories.contains(sub))
                    .contextMenu {
                        if !(isLocked && CategoryCatalog.lockedSubcategories.contains(sub)) {
                            Button("Rename…") { subcategoryName = sub; renamingSubcategory = sub }
                            Button("Delete…", role: .destructive) { deletingSubcategory = sub }
                        }
                    }
                }
                .onDelete { offsets in
                    guard let first = offsets.first else { return }
                    let sub = definition.subcategories[first]
                    if !(isLocked && CategoryCatalog.lockedSubcategories.contains(sub)) { deletingSubcategory = sub }
                }
                Button {
                    subcategoryName = ""
                    addingSubcategory = true
                } label: {
                    Label("Add Sub-category", systemImage: "plus")
                }
            } header: {
                Text("Sub-categories")
            } footer: {
                Text("Tap one to rename it. Swipe or right-click to delete it. Budgets stay at the category level.")
            }
            if !isLocked {
                let count = store.paymentCount(in: definition.name)
                Section {
                    Picker("Move payments to", selection: $moveTo) {
                        ForEach(catalog.visible.filter { $0.id != id }) { other in
                            Text(other.name).tag(other.id)
                        }
                    }
                    Button("Delete Category…", role: .destructive) { confirmingDelete = true }
                } header: {
                    Text("Delete")
                } footer: {
                    Text(count == 0
                         ? "No payments use this category. Its budgets and rules move to the category you pick."
                         : "Its \(count) payment\(count == 1 ? "" : "s"), budgets and rules move to the category you pick.")
                }
                .confirmationDialog("Delete \(definition.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete and Move to \(catalog.definition(id: moveTo)?.name ?? "Uncategorised")", role: .destructive) {
                        if let message = store.editCategories({ try $0.delete(id, movingTo: moveTo) }) {
                            error = message
                        } else {
                            dismiss()
                        }
                    }
                } message: {
                    Text("Payments, budgets and rules in \(definition.name) move to \(catalog.definition(id: moveTo)?.name ?? "Uncategorised"). Budgets in both are added together.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(definition.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = definition.name
            symbol = definition.symbol
            color = definition.color
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { save(definition) }
            }
        }
        .alert("Add sub-category", isPresented: $addingSubcategory) {
            TextField("Name", text: $subcategoryName)
            Button("Cancel", role: .cancel) {}
            Button("Add") { error = store.editCategories { try $0.addSubcategory(subcategoryName, to: id) } }
        }
        .alert("Rename sub-category", isPresented: Binding(get: { renamingSubcategory != nil }, set: { if !$0 { renamingSubcategory = nil } })) {
            TextField("Name", text: $subcategoryName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let old = renamingSubcategory {
                    error = store.editCategories { try $0.renameSubcategory(old, to: subcategoryName, in: id) }
                }
            }
        } message: {
            Text("Payments and rules using it follow the new name.")
        }
        .confirmationDialog(deletingSubcategory.map { "Delete \($0)?" } ?? "", isPresented: Binding(get: { deletingSubcategory != nil }, set: { if !$0 { deletingSubcategory = nil } }), titleVisibility: .visible) {
            if let sub = deletingSubcategory {
                Button("Delete, Keep Payments in \(definition.name)", role: .destructive) {
                    error = store.editCategories { try $0.deleteSubcategory(sub, in: id) }
                }
                ForEach(definition.subcategories.filter { $0 != sub }.prefix(6), id: \.self) { other in
                    Button("Delete, Move Payments to \(other)") {
                        error = store.editCategories { try $0.deleteSubcategory(sub, in: id, movingTo: other) }
                    }
                }
            }
        } message: {
            if let sub = deletingSubcategory {
                let count = store.paymentCount(in: definition.name, subcategory: sub)
                Text(count == 0 ? "No payments use it." : "\(count) payment\(count == 1 ? " uses" : "s use") it.")
            }
        }
    }

    private func save(_ definition: CategoryDefinition) {
        let message = store.editCategories { catalog in
            try catalog.rename(id, to: name)
            try catalog.setLook(id, symbol: symbol, color: color)
        }
        if let message { error = message } else { dismiss() }
    }
}

// MARK: Adding

struct NewCategoryView: View {
    @EnvironmentObject var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "tag"
    @State private var color = CategoryColor.violet
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                if let error { Text(error).font(.caption).foregroundStyle(Color.brandPink) }
            } header: {
                Text("Name")
            } footer: {
                Text("New categories count as spending and can have a budget. Add sub-categories once it's made.")
            }
            CategoryLookFields(symbol: $symbol, color: $color)
        }
        .formStyle(.grouped)
        .navigationTitle("New Category")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let message = store.editCategories { _ = try $0.add(name: name, symbol: symbol, color: color) }
                    if let message { error = message } else { dismiss() }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: Icon and colour

/// The icon and colour pickers, shared by the editor and New Category.
struct CategoryLookFields: View {
    @Binding var symbol: String
    @Binding var color: CategoryColor

    /// Outline SF Symbols in the same style as the built-in categories.
    static let symbols = [
        "house", "sofa", "bed.double", "lightbulb", "wrench.and.screwdriver", "bolt", "drop", "flame", "wifi", "phone",
        "cart", "basket", "fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw", "wineglass",
        "car", "fuelpump", "bus", "tram", "bicycle", "airplane", "suitcase", "map",
        "bag", "tshirt", "shippingbox", "desktopcomputer", "iphone", "tag",
        "cross.case", "stethoscope", "pills", "heart", "dumbbell", "comb", "scissors", "sparkles",
        "figure.2.and.child.holdinghands", "stroller", "pawprint", "leaf", "graduationcap", "book",
        "ticket", "film", "theatermasks", "music.note", "gamecontroller", "tv", "party.popper", "gift",
        "repeat", "banknote", "creditcard", "percent", "building.columns", "chart.line.uptrend.xyaxis",
        "briefcase", "doc.text", "umbrella", "star", "arrow.down.circle", "arrow.left.arrow.right", "questionmark.circle",
    ]

    var body: some View {
        Section("Icon") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], spacing: 8) {
                ForEach(Self.symbols, id: \.self) { name in
                    Button { symbol = name } label: {
                        IconBadge(systemImage: name, tint: name == symbol ? color.swatch : .secondary, size: 36)
                            .overlay(Circle().strokeBorder(color.swatch, lineWidth: name == symbol ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                    .accessibilityAddTraits(name == symbol ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        Section("Colour") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 10)], spacing: 10) {
                ForEach(CategoryColor.allCases, id: \.self) { option in
                    Button { color = option } label: {
                        Circle()
                            .fill(option.swatch)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: option == color ? 2 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(option == color ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
        }
    }
}
