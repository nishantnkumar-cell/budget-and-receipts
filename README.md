# BudgetMac Personal Receipt Approval

This update adds a manual-editing and approval gate before receipt splits are committed. Integrate `ApprovalView.swift`, `SplitDraft`, and the store approval methods into the full receipt-scanning project.

## Subscriptions and contracts
Add `SubscriptionView` to the Recurring section. It tracks contract start, minimum term, renewal, next payment, billing frequency, fixed-price end, notice period, expected amount and total actually paid to each vendor.

## iPhone
The shared SwiftUI source now supports iOS 17+ with a five-tab mobile interface, camera/photo receipt scanning, transaction editing, budgets, recurring contracts, review workflows and local persistence. Open Package.swift in Xcode for source validation; create or verify an iOS app target for signing, camera privacy text and device installation.
