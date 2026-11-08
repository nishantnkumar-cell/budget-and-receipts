import BudgetCore
import SwiftUI

/// Home's "Coming up": the next recurring payments, then contract renewals and deadlines.
struct ComingUpCard: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    @EnvironmentObject var store: BudgetStore
    private let planner = ComingUpPlanner()

    var body: some View {
        let now = Date()
        // Bills from Plan, and regular payments spotted on your statements.
        let payments = planner.payments(store.bills(subscriptions.contracts), from: now)
        let dates = planner.contractDates(subscriptions.contracts, from: now)
        let rises = subscriptions.priceRises(transactions: store.transactions)
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Coming up") {
                NavigationLink("Plan") { PlanView() }
            }
            if payments.isEmpty && dates.isEmpty {
                Text("Regular payments appear here once your statements show them, or add subscriptions and contracts in Plan.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !payments.isEmpty {
                section("Next payments", trailing: total(payments)) {
                    ForEach(payments.prefix(5)) { UpcomingRow(item: $0, now: now, priceRise: rises[$0.contractID]) }
                    if payments.count > 5 {
                        Text("and \(payments.count - 5) more in the next 30 days").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !dates.isEmpty {
                section("Renewals and contract dates", trailing: nil) {
                    ForEach(dates.prefix(4)) { UpcomingRow(item: $0, now: now) }
                }
            }
        }
        .card()
    }

    private func section<Content: View>(_ title: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private func total(_ payments: [UpcomingItem]) -> String {
        let totals = planner.totalDue(payments).sorted { $0.key < $1.key }
        return "30 days: " + totals.map { $0.value.formatted(.currency(code: $0.key)) }.joined(separator: " + ")
    }
}

struct UpcomingRow: View {
    let item: UpcomingItem
    let now: Date
    var priceRise: PriceRise?

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(systemImage: symbol, tint: item.kind == .cancellationDeadline ? .brandPink : .brandPlum, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.vendor).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(label) · \(when)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let amount = item.amount {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(amount, format: .currency(code: item.currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    if let priceRise { PriceRiseChip(rise: priceRise, currency: item.currency) }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch item.kind {
        case .payment: "arrow.triangle.2.circlepath"
        case .cancellationDeadline: "exclamationmark.circle"
        case .renewal: "arrow.clockwise.circle"
        case .fixedPriceEnds: "tag"
        case .minimumTermEnds: "calendar.badge.checkmark"
        }
    }

    private var label: String {
        switch item.kind {
        case .payment: item.billingPeriod.title
        case .cancellationDeadline: "Last day to cancel"
        case .renewal: "Renews"
        case .fixedPriceEnds: "Fixed price ends"
        case .minimumTermEnds: "Contract ends"
        }
    }

    private var when: String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: item.date)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case 2...13: return "in \(days) days, \(item.date.formatted(.dateTime.weekday(.abbreviated).day()))"
        default: return item.date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
