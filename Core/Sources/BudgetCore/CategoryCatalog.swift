import Foundation

/// A colour for a category, named so each app can map it to its own palette.
public enum CategoryColor: String, Codable, CaseIterable, Hashable, Sendable {
    case violet, magenta, teal, amber, green, blue, orange, red, pink, indigo, mint, brown, graphite

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// One category: its name, icon, colour and sub-categories. Built-in categories have their
/// original name as `id`, so payments and starter rules that still use that name find them.
/// Your own categories have an id starting "custom-".
///
/// Categories are never removed from the list. A deleted one is kept, marked deleted, with the
/// category its payments moved to, so a payment that arrives later from another device (or a
/// starter rule, look-up or Apple Intelligence that still says the old name) moves there too.
public struct CategoryDefinition: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// An SF Symbol name.
    public var symbol: String
    public var color: CategoryColor
    public var subcategories: [String]
    public var isCustom: Bool
    /// When you added it, so your own categories keep their order on every device.
    public var createdAt: Date?
    public var isDeleted: Bool?
    /// The id of the category a deleted category's payments moved to.
    public var mergedInto: String?
    /// Names this category had before, so payments still using one move to the new name.
    public var formerNames: [String]?
    /// Renamed or deleted sub-categories: old name → new name, or "" for no sub-category.
    public var subcategoryMoves: [String: String]?

    public init(id: String, name: String, symbol: String, color: CategoryColor, subcategories: [String] = [],
                isCustom: Bool = false, createdAt: Date? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.subcategories = subcategories
        self.isCustom = isCustom
        self.createdAt = createdAt
    }

    public var deleted: Bool { isDeleted == true }
}

public enum CategoryEditError: Error, Equatable, Sendable {
    case emptyName
    case nameTaken
    /// Income, transfers, card payments, savings and Uncategorised drive the money rules.
    case builtInLocked
    case notFound

    public var message: String {
        switch self {
        case .emptyName: "Give it a name."
        case .nameTaken: "There's already a category or sub-category with that name."
        case .builtInLocked: "This category is used by the app's money rules, so it can't be renamed or deleted."
        case .notFound: "That category no longer exists."
        }
    }
}

/// The household's categories: the built-in ones as you've changed them, plus your own.
/// Saved changes are only the categories that differ from the built-in list.
public struct CategoryCatalog: Hashable, Sendable {
    /// Every category, deleted ones included, in display order.
    public private(set) var definitions: [CategoryDefinition]

    /// The built-in categories, as the app ships them.
    public static let builtIn: [CategoryDefinition] = {
        let looks: [String: (String, CategoryColor)] = [
            "Housing": ("house", .brown),
            "Bills & utilities": ("bolt", .amber),
            "Groceries": ("cart", .green),
            "Eating out": ("fork.knife", .orange),
            "Transport": ("car", .blue),
            "Shopping": ("bag", .magenta),
            "Health": ("cross.case", .red),
            "Personal care": ("comb", .pink),
            "Family": ("figure.2.and.child.holdinghands", .indigo),
            "Entertainment": ("ticket", .violet),
            "Subscriptions": ("repeat", .teal),
            "Travel": ("airplane", .mint),
            "Education": ("graduationcap", .indigo),
            "Gifts & charity": ("gift", .pink),
            "Cash": ("banknote", .green),
            "Fees & charges": ("percent", .red),
            "Savings & investments": ("building.columns", .teal),
            "Income": ("arrow.down.circle", .green),
            "Card payment": ("creditcard", .graphite),
            "Internal transfer": ("arrow.left.arrow.right", .graphite),
            "Uncategorised": ("questionmark.circle", .graphite),
        ]
        return FinanceCategories.builtInNames.map { name in
            let look = looks[name] ?? ("questionmark.circle", .graphite)
            return CategoryDefinition(id: name, name: name, symbol: look.0, color: look.1,
                                      subcategories: FinanceCategories.defaultSubcategories[name] ?? [])
        }
    }()

    /// Categories the money rules depend on by name: they keep their names and can't be
    /// deleted. Their icon, colour and sub-categories can still change.
    public static let lockedIDs: Set<String> = ["Income", "Card payment", "Internal transfer", "Savings & investments", "Uncategorised"]

    public static let `default` = CategoryCatalog(saved: [])

    /// - Parameter saved: changed built-in categories and your own, from any device.
    public init(saved: [CategoryDefinition]) {
        let byID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var builtIn = Self.builtIn.map { byID[$0.id] ?? $0 }
        for index in builtIn.indices where Self.lockedIDs.contains(builtIn[index].id) {
            // A locked category always keeps its name and stays, whatever arrives.
            builtIn[index].name = builtIn[index].id
            builtIn[index].isDeleted = nil
            builtIn[index].mergedInto = nil
            builtIn[index].isCustom = false
        }
        let builtInIDs = Set(Self.builtIn.map(\.id))
        let custom = saved.filter { !builtInIDs.contains($0.id) && $0.isCustom }
            .sorted { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
        // Your own categories sit after the built-in spending ones, before income and transfers.
        let firstMoneyMove = builtIn.firstIndex { FinanceCategories.nonBudget.contains($0.id) } ?? builtIn.endIndex
        builtIn.insert(contentsOf: custom, at: firstMoneyMove)
        definitions = builtIn
    }

    /// The definitions worth saving: your own categories and built-in ones you've changed.
    public var changed: [CategoryDefinition] {
        let original = Dictionary(Self.builtIn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return definitions.filter { definition in definition.isCustom || original[definition.id] != definition }
    }

    // MARK: Reading

    /// Categories in use (not deleted), in display order.
    public var visible: [CategoryDefinition] { definitions.filter { !$0.deleted } }

    public var all: [String] { visible.map(\.name) }

    /// Categories that spend money, so they can have a budget.
    public var budgetable: [String] { visible.filter { !FinanceCategories.nonBudget.contains($0.id) }.map(\.name) }

    public func definition(id: String) -> CategoryDefinition? { definitions.first { $0.id == id } }

    /// The category with this name now, following renames and deletions.
    public func definition(named name: String) -> CategoryDefinition? {
        let resolved = resolve(name)
        return visible.first { $0.name == resolved }
    }

    public func subcategories(of category: String) -> [String] { definition(named: category)?.subcategories ?? [] }

    public func isLocked(_ definition: CategoryDefinition) -> Bool { Self.lockedIDs.contains(definition.id) }

    /// The name a category has now. Follows renames and deletions; a name the list doesn't
    /// know (e.g. a category another device added that hasn't arrived yet) stays as it is.
    public func resolve(_ name: String) -> String {
        resolveDefinition(name)?.name ?? name
    }

    /// A category and sub-category as they are now. A sub-category that was renamed follows
    /// the new name; one that was deleted, or doesn't belong to the category a payment moved
    /// to, is dropped.
    public func resolve(category: String, subcategory: String?) -> (category: String, subcategory: String?) {
        guard let start = visible.first(where: { $0.name == category }) ?? lookUp(category) else {
            return (category, subcategory)
        }
        var definition = start
        var sub = subcategory.flatMap { $0.isEmpty ? nil : $0 }
        sub = sub.flatMap { moved($0, in: definition) }
        var steps = 0
        while definition.deleted, let target = definition.mergedInto.flatMap(self.definition(id:)), steps < 10 {
            definition = target
            sub = sub.flatMap { target.subcategories.contains($0) ? $0 : nil }
            steps += 1
        }
        guard !definition.deleted else { return ("Uncategorised", nil) }
        return (definition.name, sub)
    }

    private func moved(_ sub: String, in definition: CategoryDefinition) -> String? {
        var current = sub
        for _ in 0..<10 {
            guard let next = definition.subcategoryMoves?[current] else { break }
            if next.isEmpty { return nil }
            current = next
        }
        return current
    }

    /// A definition by name: current names first, then built-in ids and former names.
    private func lookUp(_ name: String) -> CategoryDefinition? {
        definitions.first { $0.name == name && !$0.deleted }
            ?? definitions.first { $0.id == name }
            ?? definitions.first { $0.formerNames?.contains(name) == true }
            ?? definitions.first { $0.name == name }
    }

    private func resolveDefinition(_ name: String) -> CategoryDefinition? {
        guard var definition = lookUp(name) else { return nil }
        var steps = 0
        while definition.deleted, steps < 10 {
            guard let target = definition.mergedInto.flatMap(self.definition(id:)) else {
                return visible.first { $0.id == "Uncategorised" }
            }
            definition = target
            steps += 1
        }
        return definition.deleted ? visible.first { $0.id == "Uncategorised" } : definition
    }

    // MARK: Changing

    private func position(of id: String) throws -> Int {
        guard let index = definitions.firstIndex(where: { $0.id == id && !$0.deleted }) else { throw CategoryEditError.notFound }
        return index
    }

    private func cleaned(_ name: String) -> String {
        name.replacingOccurrences(of: "›", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkName(_ name: String, except id: String?) throws {
        guard !name.isEmpty else { throw CategoryEditError.emptyName }
        let taken = visible.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if taken { throw CategoryEditError.nameTaken }
    }

    /// Adds your own category. Returns it.
    @discardableResult
    public mutating func add(name: String, symbol: String, color: CategoryColor, now: Date = Date()) throws -> CategoryDefinition {
        let name = cleaned(name)
        try checkName(name, except: nil)
        let definition = CategoryDefinition(id: "custom-\(UUID().uuidString)", name: name, symbol: symbol, color: color, isCustom: true, createdAt: now)
        let firstMoneyMove = definitions.firstIndex { FinanceCategories.nonBudget.contains($0.id) } ?? definitions.endIndex
        definitions.insert(definition, at: firstMoneyMove)
        return definition
    }

    /// Renames a category. Payments, budgets and rules using the old name follow it.
    public mutating func rename(_ id: String, to newName: String) throws {
        let index = try position(of: id)
        let newName = cleaned(newName)
        let old = definitions[index].name
        guard newName != old else { return }
        guard !isLocked(definitions[index]) else { throw CategoryEditError.builtInLocked }
        try checkName(newName, except: id)
        var former = definitions[index].formerNames ?? []
        former.removeAll { $0 == newName }
        if !former.contains(old) { former.append(old) }
        definitions[index].formerNames = former
        definitions[index].name = newName
    }

    public mutating func setLook(_ id: String, symbol: String, color: CategoryColor) throws {
        let index = try position(of: id)
        definitions[index].symbol = symbol
        definitions[index].color = color
    }

    /// Deletes a category. Its payments, budgets and rules move to `targetID`.
    public mutating func delete(_ id: String, movingTo targetID: String) throws {
        let index = try position(of: id)
        guard !isLocked(definitions[index]) else { throw CategoryEditError.builtInLocked }
        guard targetID != id else { throw CategoryEditError.notFound }
        _ = try position(of: targetID)
        definitions[index].isDeleted = true
        definitions[index].mergedInto = targetID
        // Anything that had been merged into this one now goes straight to the new target.
        for other in definitions.indices where definitions[other].mergedInto == id {
            definitions[other].mergedInto = targetID
        }
    }

    public mutating func addSubcategory(_ name: String, to id: String) throws {
        let index = try position(of: id)
        let name = cleaned(name)
        guard !name.isEmpty else { throw CategoryEditError.emptyName }
        guard !definitions[index].subcategories.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { throw CategoryEditError.nameTaken }
        definitions[index].subcategories.append(name)
        definitions[index].subcategoryMoves?[name] = nil
    }

    /// Renames a sub-category. Payments and rules using the old name follow it.
    public mutating func renameSubcategory(_ old: String, to newName: String, in id: String) throws {
        let index = try position(of: id)
        let newName = cleaned(newName)
        guard newName != old else { return }
        guard let position = definitions[index].subcategories.firstIndex(of: old) else { throw CategoryEditError.notFound }
        guard !newName.isEmpty else { throw CategoryEditError.emptyName }
        let taken = definitions[index].subcategories.contains { $0 != old && $0.caseInsensitiveCompare(newName) == .orderedSame }
        if taken { throw CategoryEditError.nameTaken }
        if isLocked(definitions[index]), Self.lockedSubcategories.contains(old) { throw CategoryEditError.builtInLocked }
        definitions[index].subcategories[position] = newName
        var moves = definitions[index].subcategoryMoves ?? [:]
        moves[newName] = nil
        // Earlier names that led to the old one now lead to the new one.
        for (key, value) in moves where value == old { moves[key] = newName }
        moves[old] = newName
        definitions[index].subcategoryMoves = moves
    }

    /// Deletes a sub-category. Its payments move to `target` in the same category, or keep
    /// just the category when it's nil.
    public mutating func deleteSubcategory(_ name: String, in id: String, movingTo target: String? = nil) throws {
        let index = try position(of: id)
        guard let position = definitions[index].subcategories.firstIndex(of: name) else { throw CategoryEditError.notFound }
        if isLocked(definitions[index]), Self.lockedSubcategories.contains(name) { throw CategoryEditError.builtInLocked }
        let destination = target.flatMap { $0 != name && definitions[index].subcategories.contains($0) ? $0 : nil } ?? ""
        definitions[index].subcategories.remove(at: position)
        var moves = definitions[index].subcategoryMoves ?? [:]
        for (key, value) in moves where value == name { moves[key] = destination }
        moves[name] = destination
        definitions[index].subcategoryMoves = moves
    }

    /// Sub-categories the money rules depend on: refunds and payments between the two of you.
    public static let lockedSubcategories: Set<String> = ["Refund", "Between you", "Between accounts", "Credit card repayment"]

    /// Puts the built-in categories back as the app ships them. Renamed ones get their names
    /// back and their payments follow; deleted ones come back empty (payments already moved
    /// stay where they are). Your own categories are kept.
    public mutating func restoreBuiltIn() {
        for index in definitions.indices where !definitions[index].isCustom {
            guard let original = Self.builtIn.first(where: { $0.id == definitions[index].id }) else { continue }
            let current = definitions[index]
            var restored = original
            // Names it had stay as former names, so payments using them come back too.
            let former = Set((current.formerNames ?? []) + (current.deleted ? [] : [current.name])).subtracting([original.name])
            restored.formerNames = former.isEmpty ? nil : former.sorted()
            // Renamed sub-categories that are built in come back to their original names.
            var moves: [String: String] = [:]
            for (old, new) in current.subcategoryMoves ?? [:] where !original.subcategories.contains(old) { moves[old] = new }
            for sub in current.subcategories where !original.subcategories.contains(sub) {
                let back = (current.subcategoryMoves ?? [:]).first { original.subcategories.contains($0.key) && $0.value == sub }?.key
                moves[sub] = back ?? ""
            }
            restored.subcategoryMoves = moves.isEmpty ? nil : moves
            definitions[index] = restored
        }
        // Your own categories that had been merged into a built-in one stay merged.
        // Names a custom category uses that clash with a restored name: the built-in wins.
        for index in definitions.indices where definitions[index].isCustom && !definitions[index].deleted {
            let clash = definitions.contains { !$0.isCustom && $0.name.caseInsensitiveCompare(definitions[index].name) == .orderedSame }
            if clash { definitions[index].name += " (mine)" }
        }
    }
}

// MARK: Keeping data in step

/// Moves payments, receipt items, budgets, rules and look-ups that still use an old category
/// or sub-category name to the name it has now. Runs after every change to the categories and
/// whenever data arrives from another device, so nothing is left in a renamed or deleted one.
public struct CategoryNormaliser {
    public let catalog: CategoryCatalog
    private var cache: [String: (category: String, subcategory: String?)] = [:]

    public init(catalog: CategoryCatalog) {
        self.catalog = catalog
    }

    /// True when nothing has been renamed or deleted, so there is nothing to move.
    public var isIdentity: Bool {
        !catalog.definitions.contains { $0.deleted || !($0.formerNames ?? []).isEmpty || !($0.subcategoryMoves ?? [:]).isEmpty || ($0.name != $0.id && !$0.isCustom) }
    }

    private mutating func resolve(_ category: String, _ subcategory: String?) -> (category: String, subcategory: String?) {
        let key = category + "\u{1}" + (subcategory ?? "\u{2}")
        if let hit = cache[key] { return hit }
        let result = catalog.resolve(category: category, subcategory: subcategory)
        cache[key] = result
        return result
    }

    private mutating func resolve(_ category: String) -> String { resolve(category, nil).category }

    /// Returns true when the transaction changed.
    @discardableResult
    public mutating func normalise(_ transaction: inout BankTransaction) -> Bool {
        let before = transaction
        let now = resolve(transaction.category, transaction.subcategory)
        transaction.category = now.category
        if transaction.subcategory != nil || now.subcategory != nil { transaction.subcategory = now.subcategory }
        for index in transaction.splits.indices {
            transaction.splits[index].category = resolve(transaction.splits[index].category)
        }
        if var draft = transaction.pendingSplitDraft {
            for index in draft.proposedSplits.indices { draft.proposedSplits[index].category = resolve(draft.proposedSplits[index].category) }
            for index in draft.receipt.items.indices { draft.receipt.items[index].category = resolve(draft.receipt.items[index].category) }
            if draft != before.pendingSplitDraft { transaction.pendingSplitDraft = draft }
        }
        return transaction != before
    }

    @discardableResult
    public mutating func normalise(_ transactions: inout [BankTransaction]) -> Bool {
        var changed = false
        for index in transactions.indices where normalise(&transactions[index]) { changed = true }
        return changed
    }

    @discardableResult
    public mutating func normalise(_ editor: inout ReceiptDraftEditor) -> Bool {
        var changed = false
        for index in editor.items.indices {
            let now = resolve(editor.items[index].category)
            if now != editor.items[index].category { editor.items[index].category = now; changed = true }
        }
        return changed
    }

    @discardableResult
    public mutating func normalise(_ receipts: inout [PendingReceipt]) -> Bool {
        var changed = false
        for index in receipts.indices where normalise(&receipts[index].editor) { changed = true }
        return changed
    }

    @discardableResult
    public mutating func normalise(_ rules: inout [CategoryRule]) -> Bool {
        var changed = false
        for index in rules.indices {
            let now = resolve(rules[index].category, rules[index].subcategory)
            if now.category != rules[index].category || now.subcategory != rules[index].subcategory {
                rules[index].category = now.category
                rules[index].subcategory = now.subcategory
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    public mutating func normalise(_ lookedUp: inout [String: MerchantCategory]) -> Bool {
        var changed = false
        for (key, value) in lookedUp {
            let now = resolve(value.category)
            if now != value.category { lookedUp[key]?.category = now; changed = true }
        }
        return changed
    }

    @discardableResult
    public mutating func normalise(_ couple: inout CoupleSettings) -> Bool {
        var changed = false
        for index in couple.rules.indices {
            guard case .category(let name) = couple.rules[index].match else { continue }
            let now = resolve(name)
            if now != name { couple.rules[index].match = .category(now); changed = true }
        }
        return changed
    }

    /// Budgets follow their category. When two end up in the same category for the same
    /// month (one category deleted into another), they become one budget with both limits.
    @discardableResult
    public mutating func normalise(_ budgets: inout [MonthlyBudget], calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        var changed = false
        for index in budgets.indices {
            let now = resolve(budgets[index].category)
            if now != budgets[index].category { budgets[index].category = now; changed = true }
        }
        guard changed else { return false }
        var merged: [MonthlyBudget] = []
        for budget in budgets {
            let start = calendar.dateInterval(of: .month, for: budget.month)?.start ?? budget.month
            if let index = merged.firstIndex(where: { $0.category == budget.category && (calendar.dateInterval(of: .month, for: $0.month)?.start ?? $0.month) == start }) {
                merged[index].limit += budget.limit
                if budget.rollover == true { merged[index].rollover = true }
                if budget.removed != true { merged[index].removed = nil }
            } else {
                merged.append(budget)
            }
        }
        budgets = merged
        return true
    }
}
