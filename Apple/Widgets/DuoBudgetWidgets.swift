import AppIntents
import SwiftUI
import WidgetKit

// Home Screen, Lock Screen and desktop widgets: safe to spend and the next bill. Plus the
// Control Centre button that opens the camera to scan a receipt.

@main
struct DuoBudgetWidgets: WidgetBundle {
    var body: some Widget {
        SafeToSpendWidget()
        NextBillWidget()
        #if os(iOS)
        ScanReceiptControl()
        #endif
    }
}

/// The app's violet (Graphite and violet theme).
private let violet = Color(red: 0x5E / 255, green: 0x5C / 255, blue: 0xE6 / 255)

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .placeholder : WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads the widgets when its figures change; the next morning they move on a day.
        let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        completion(Timeline(entries: [SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.read())], policy: .after(tomorrow)))
    }
}

// MARK: Safe to spend

struct SafeToSpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kinds.safeToSpend, provider: SnapshotProvider()) { entry in
            SafeToSpendView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "duobudget://budgets"))
        }
        .configurationDisplayName("Safe to spend")
        .description("What you can spend today and still stay within this month's budgets, after bills.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline, .accessoryCircular])
        #else
        .supportedFamilies([.systemSmall])
        #endif
    }
}

struct SafeToSpendView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?

    var body: some View {
        if let snapshot, snapshot.showsAmounts, let today = snapshot.safeToday {
            switch family {
            case .accessoryInline:
                Text("\(snapshot.money(today)) a day to spend").privacySensitive()
            case .accessoryCircular:
                VStack(spacing: 0) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.caption2)
                    Text(snapshot.money(today)).font(.caption.weight(.semibold)).minimumScaleFactor(0.6).privacySensitive()
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("Safe to spend", systemImage: "gauge.with.dots.needle.67percent").font(.caption2.weight(.semibold))
                    Text("\(snapshot.money(today)) today").font(.headline).privacySensitive()
                    if let left = snapshot.leftThisMonth {
                        Text("\(snapshot.money(left)) left this month").font(.caption2).privacySensitive()
                    }
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Safe to spend", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(violet)
                    Spacer(minLength: 0)
                    Text(snapshot.money(today))
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .minimumScaleFactor(0.6)
                        .privacySensitive()
                    Text("a day for \(snapshot.daysLeft ?? 0) more day\(snapshot.daysLeft == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let left = snapshot.leftThisMonth, let bills = snapshot.billsStillToCome {
                        Text("\(snapshot.money(left)) left, \(snapshot.money(bills)) of bills to come")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            .privacySensitive()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        } else {
            EmptyWidgetView(symbol: "gauge.with.dots.needle.67percent", title: "Safe to spend",
                            message: snapshot?.showsAmounts == false ? "Open Duo Budget to see it." : "Set a budget in Duo Budget to see this.")
        }
    }
}

// MARK: Next bill

struct NextBillWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kinds.nextBill, provider: SnapshotProvider()) { entry in
            NextBillView(snapshot: entry.snapshot, now: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "duobudget://plan"))
        }
        .configurationDisplayName("Next bill")
        .description("Your next bills and when they're due.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium])
        #endif
    }
}

struct NextBillView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot?
    let now: Date

    private func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        let bills = (snapshot?.bills ?? []).filter { $0.date >= Calendar.current.startOfDay(for: now) }
        if let snapshot, snapshot.showsAmounts, let next = bills.first {
            switch family {
            case .accessoryInline:
                Text("\(next.name) \(snapshot.money(next.amount)) \(when(next.date))").privacySensitive()
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("Next bill", systemImage: "calendar").font(.caption2.weight(.semibold))
                    Text(next.name).font(.headline).lineLimit(1)
                    Text("\(snapshot.money(next.amount)) · \(when(next.date))").font(.caption).privacySensitive()
                }
            case .systemMedium:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Next bills", systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(violet)
                    ForEach(bills.prefix(3), id: \.self) { bill in
                        HStack {
                            Text(bill.name).lineLimit(1)
                            Spacer()
                            Text(when(bill.date)).foregroundStyle(.secondary)
                            Text(snapshot.money(bill.amount)).fontWeight(.semibold).monospacedDigit().privacySensitive()
                        }
                        .font(.subheadline)
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Label("Next bill", systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(violet)
                    Spacer(minLength: 0)
                    Text(next.name).font(.headline).lineLimit(2)
                    Text(snapshot.money(next.amount)).font(.system(.title2, design: .rounded).weight(.bold)).privacySensitive()
                    Text(when(next.date)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        } else {
            EmptyWidgetView(symbol: "calendar", title: "Next bill",
                            message: snapshot?.showsAmounts == false ? "Open Duo Budget to see it." : "No bills coming up.")
        }
    }
}

struct EmptyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        switch family {
        case .accessoryInline: Label(title, systemImage: symbol)
        case .accessoryCircular: Image(systemName: symbol).font(.title3)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(violet)
                Spacer(minLength: 0)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: Control Centre

#if os(iOS)
/// A Control Centre, Lock Screen or Action button control that opens Duo Budget's camera.
struct ScanReceiptControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ScanReceipt") {
            ControlWidgetButton(action: OpenScanIntent()) {
                Label("Scan Receipt", systemImage: "doc.viewfinder")
            }
        }
        .displayName("Scan Receipt")
        .description("Opens Duo Budget ready to scan a receipt.")
    }
}
#endif
