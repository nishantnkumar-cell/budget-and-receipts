#if os(macOS)
import BudgetCore
import SwiftUI

// The Mac Overview as a grid of widgets. Each widget snaps to a 12-column grid and every
// row shares one height, so edges always line up. Edit mode adds, removes, resizes and reorders.

/// Keeps the layout in this Mac's preferences.
@MainActor
final class DashboardLayoutStore: ObservableObject {
    private static let key = "macDashboardLayout"
    private let defaults: UserDefaults

    @Published var layout: DashboardLayout {
        didSet { defaults.set(layout.encoded(), forKey: Self.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = DashboardLayout.decoded(from: defaults.data(forKey: Self.key))
    }
}

private struct SpanKey: LayoutValueKey { static let defaultValue = 12 }
private struct HeightKey: LayoutValueKey { static let defaultValue: CGFloat = 100 }

/// Packs widgets into rows of 12 columns. A narrow window doubles every width, so tiles go two across.
struct DashboardFlow: Layout {
    var spacing: CGFloat = 16

    private func frames(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let scale = width < 720 ? 2 : 1
        let column = max((width - 11 * spacing) / 12, 0)
        var rows: [[Int]] = []
        var used = 0
        for index in subviews.indices {
            let span = min(subviews[index][SpanKey.self] * scale, 12)
            if rows.isEmpty || used + span > 12 {
                rows.append([index])
                used = span
            } else {
                rows[rows.count - 1].append(index)
                used += span
            }
        }
        var result = [CGRect](repeating: .zero, count: subviews.count)
        var y: CGFloat = 0
        for row in rows {
            let height = row.map { subviews[$0][HeightKey.self] }.max() ?? 0
            var start = 0
            for index in row {
                let span = min(subviews[index][SpanKey.self] * scale, 12)
                result[index] = CGRect(x: CGFloat(start) * (column + spacing), y: y,
                                       width: CGFloat(span) * column + CGFloat(span - 1) * spacing, height: height)
                start += span
            }
            y += height + spacing
        }
        return (result, max(y - spacing, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        return CGSize(width: width, height: frames(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = frames(subviews, width: bounds.width)
        for index in subviews.indices {
            let frame = plan.frames[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

struct MacDashboard: View {
    @EnvironmentObject var store: BudgetStore
    @ObservedObject var layoutStore: DashboardLayoutStore
    let report: MonthlyBudgetReport
    let query: String
    let editing: Bool
    @Binding var selection: AppSection?

    private var shown: [DashboardLayout.Item] {
        layoutStore.layout.items.filter { editing || !(store.selectedMonthIsEmpty && $0.kind.isTile) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.selectedMonthIsEmpty { EmptyMonthNotice() }
            if editing {
                Text("Drag a widget to move it, or use its Options menu to resize, move or remove it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                ContentUnavailableView("No widgets", systemImage: "square.dashed",
                                       description: Text(editing ? "Choose Add Widget to put one back." : "Choose Customise, then Add Widget."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                DashboardFlow {
                    ForEach(shown) { item in
                        widget(item)
                            .layoutValue(key: SpanKey.self, value: item.size.columns)
                            .layoutValue(key: HeightKey.self, value: item.kind.height)
                    }
                }
            }
        }
    }

    @ViewBuilder private func widget(_ item: DashboardLayout.Item) -> some View {
        let kind = item.kind
        let body = content(kind)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(!editing)
        if editing {
            body
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                .overlay(alignment: .topTrailing) { options(for: item) }
                .draggable(kind.rawValue)
                .dropDestination(for: String.self) { dropped, _ in
                    guard let moving = dropped.first.flatMap(DashboardWidgetKind.init(rawValue:)) else { return false }
                    layoutStore.layout.move(moving, onto: kind)
                    return true
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(kind.title)
        } else {
            body
        }
    }

    @ViewBuilder private func content(_ kind: DashboardWidgetKind) -> some View {
        switch kind {
        case .spend, .safeToSpend, .balanceOrIncome, .bills, .netWorth:
            OverviewKeyNumbers(report: report, only: kind)
        case .pace: SpendingPacePanel(report: report)
        case .needsYou: NeedsYouPanel(open: { selection = $0 })
        case .nextDays: NextDaysPanel()
        case .activity: MacRecentActivity(query: query, selection: $selection)
        }
    }

    private func options(for item: DashboardLayout.Item) -> some View {
        let kind = item.kind
        return Menu {
            Picker("Size", selection: Binding(get: { item.size }, set: { layoutStore.layout.resize(kind, to: $0) })) {
                ForEach(kind.sizes) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Move Earlier") { layoutStore.layout.nudge(kind, by: -1) }
                .disabled(!layoutStore.layout.canNudge(kind, by: -1))
            Button("Move Later") { layoutStore.layout.nudge(kind, by: 1) }
                .disabled(!layoutStore.layout.canNudge(kind, by: 1))
            Divider()
            Button("Remove", role: .destructive) { layoutStore.layout.remove(kind) }
        } label: {
            Label("Options for \(kind.title)", systemImage: "ellipsis.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(width: 32, height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(6)
    }
}

/// Toolbar buttons for the dashboard: Customise / Done, and Add Widget while customising.
struct DashboardToolbar: ToolbarContent {
    @ObservedObject var layoutStore: DashboardLayoutStore
    @Binding var editing: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if editing {
                Menu {
                    ForEach(layoutStore.layout.hidden) { kind in
                        Button(kind.title) { layoutStore.layout.add(kind) }
                    }
                } label: {
                    Label("Add Widget", systemImage: "plus")
                }
                .disabled(layoutStore.layout.hidden.isEmpty)
                .help(layoutStore.layout.hidden.isEmpty ? "Every widget is already on the Overview" : "Add a widget")
                Button("Reset Layout") { layoutStore.layout = .standard }
                    .disabled(layoutStore.layout == .standard)
                Button("Done") { editing = false }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button { editing = true } label: { Label("Customise", systemImage: "square.grid.2x2") }
                    .help("Add, remove, resize and move widgets")
            }
        }
    }
}
#endif
