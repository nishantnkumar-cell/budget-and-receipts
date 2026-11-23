import Foundation

/// The widgets the Mac Overview can show. Each one appears at most once.
public enum DashboardWidgetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case spend, safeToSpend, balanceOrIncome, bills, netWorth
    case pace, needsYou, nextDays, activity

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .spend: "Left to spend"
        case .safeToSpend: "Safe to spend today"
        case .balanceOrIncome: "Income or partner balance"
        case .bills: "Bills, next 30 days"
        case .netWorth: "Net worth"
        case .pace: "Spending pace"
        case .needsYou: "Needs you"
        case .nextDays: "Next 7 days"
        case .activity: "Month activity"
        }
    }

    /// Key-number tiles are short; the others are panels.
    public var isTile: Bool {
        switch self {
        case .spend, .safeToSpend, .balanceOrIncome, .bills, .netWorth: true
        default: false
        }
    }

    /// Every widget in a row shares that row's height, so edges always line up.
    public var height: Double {
        switch self {
        case .spend, .safeToSpend, .balanceOrIncome, .bills, .netWorth: 104
        case .pace, .needsYou, .nextDays: 330
        case .activity: 400
        }
    }

    public var defaultSize: DashboardWidgetSize {
        switch self {
        case .spend, .safeToSpend, .balanceOrIncome, .bills, .netWorth, .needsYou, .nextDays: .small
        case .pace: .medium
        case .activity: .full
        }
    }

    /// Sizes that make sense for this widget.
    public var sizes: [DashboardWidgetSize] {
        isTile ? [.small, .medium] : DashboardWidgetSize.allCases
    }
}

/// Width on a 12-column grid: a quarter, a half, two thirds or the full row.
public enum DashboardWidgetSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, medium, wide, full

    public var id: String { rawValue }

    public var columns: Int {
        switch self {
        case .small: 3
        case .medium: 6
        case .wide: 8
        case .full: 12
        }
    }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .wide: "Wide"
        case .full: "Full width"
        }
    }
}

/// Which widgets are on the Overview, in order, and how wide each is.
public struct DashboardLayout: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var kind: DashboardWidgetKind
        public var size: DashboardWidgetSize
        public var id: DashboardWidgetKind { kind }

        public init(kind: DashboardWidgetKind, size: DashboardWidgetSize? = nil) {
            self.kind = kind
            self.size = size ?? kind.defaultSize
        }
    }

    public private(set) var items: [Item]

    public init(items: [Item]) {
        var seen = Set<DashboardWidgetKind>()
        self.items = items.filter { seen.insert($0.kind).inserted }
    }

    /// What the Overview showed before it could be changed.
    public static let standard = DashboardLayout(items: [
        .init(kind: .spend), .init(kind: .safeToSpend), .init(kind: .balanceOrIncome), .init(kind: .bills),
        .init(kind: .pace), .init(kind: .needsYou), .init(kind: .nextDays),
        .init(kind: .activity),
    ])

    public var hidden: [DashboardWidgetKind] {
        DashboardWidgetKind.allCases.filter { kind in !items.contains { $0.kind == kind } }
    }

    public func contains(_ kind: DashboardWidgetKind) -> Bool { items.contains { $0.kind == kind } }

    public mutating func add(_ kind: DashboardWidgetKind) {
        guard !contains(kind) else { return }
        items.append(Item(kind: kind))
    }

    public mutating func remove(_ kind: DashboardWidgetKind) {
        items.removeAll { $0.kind == kind }
    }

    public mutating func resize(_ kind: DashboardWidgetKind, to size: DashboardWidgetSize) {
        guard kind.sizes.contains(size), let index = items.firstIndex(where: { $0.kind == kind }) else { return }
        items[index].size = size
    }

    /// Puts `kind` where `target` is now (drag and drop).
    public mutating func move(_ kind: DashboardWidgetKind, onto target: DashboardWidgetKind) {
        guard kind != target,
              let from = items.firstIndex(where: { $0.kind == kind }),
              let to = items.firstIndex(where: { $0.kind == target }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    /// One step earlier or later (the keyboard alternative to dragging).
    public mutating func nudge(_ kind: DashboardWidgetKind, by offset: Int) {
        guard let from = items.firstIndex(where: { $0.kind == kind }) else { return }
        let to = min(max(from + offset, 0), items.count - 1)
        guard to != from else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    public func canNudge(_ kind: DashboardWidgetKind, by offset: Int) -> Bool {
        guard let index = items.firstIndex(where: { $0.kind == kind }) else { return false }
        return items.indices.contains(index + offset)
    }

    // MARK: Saving

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// Reads a saved layout. Widgets this version doesn't know are dropped, and anything unreadable gives `standard`.
    public static func decoded(from data: Data?) -> DashboardLayout {
        guard let data, let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return .standard }
        let items = raw.items.compactMap { entry -> Item? in
            guard let kind = DashboardWidgetKind(rawValue: entry.kind) else { return nil }
            let size = entry.size.flatMap(DashboardWidgetSize.init(rawValue:))
            return Item(kind: kind, size: size.flatMap { kind.sizes.contains($0) ? $0 : nil })
        }
        return DashboardLayout(items: items)
    }

    private struct Raw: Decodable {
        struct Entry: Decodable { var kind: String; var size: String? }
        var items: [Entry]
    }
}

/// Where each widget lands on a 12-column grid. Shared by the view and the tests.
public enum DashboardGrid {
    public static let columns = 12

    /// Groups items into rows that each fit in 12 columns, in order.
    public static func rows(_ items: [DashboardLayout.Item], scale: Int = 1) -> [[DashboardLayout.Item]] {
        var rows: [[DashboardLayout.Item]] = []
        var used = 0
        for item in items {
            let span = min(item.size.columns * scale, columns)
            if rows.isEmpty || used + span > columns {
                rows.append([item])
                used = span
            } else {
                rows[rows.count - 1].append(item)
                used += span
            }
        }
        return rows
    }
}
