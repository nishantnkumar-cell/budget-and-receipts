# Independent Validation and Security Review Handoff

## Purpose

This package is being handed to a second AI/LLM for independent testing, code review, build validation and a full security scan. The reviewer should treat the source code as authoritative. This document describes the intended behaviour and the code's current integration state. It does **not** claim that the project compiles or that any existing test passes. The second reviewer must establish those facts independently with the latest stable Xcode selected on the review Mac.

## Review priorities

1. Establish whether `Package.swift` resolves and the executable target compiles.
2. Run the existing tests without changing production code first.
3. Identify compile failures, runtime failures, missing wiring and unsafe assumptions.
4. Add an independent test suite covering the behaviours and risks listed below.
5. Run static security analysis, secrets/PII scanning, dependency and entitlement review, malformed-input testing and local-data privacy checks.
6. Produce a severity-ranked report with reproducible evidence, affected files/lines and recommended fixes.

## Honest current-state summary

The package is currently a **feature prototype**, not a verified complete five-section application.

- The executable entry point in `App.swift` creates an empty `BudgetStore` and shows `ApprovalView` only if a transaction already exists. There is currently no production import path in this package that populates `BudgetStore.transactions`, so a normal launch is expected to show the empty-state view.
- `ReceiptVisionService.swift` contains local Apple Vision OCR and receipt parsing, but `ApprovalView.swift` does not currently invoke `ReceiptVisionService`. Receipt fields and line items are manually entered in the current UI.
- `SubscriptionView.swift` is implemented, but it is not currently mounted from `App.swift`.
- `SubscriptionStore` persists contracts as JSON under Application Support, but transaction, receipt-draft, split and audit persistence are not implemented in the current `BudgetStore`.
- The package declares macOS 14 and Swift tools 6.0. Apple Vision/AppKit therefore require a macOS/Xcode build environment.
- Existing tests are included, but this handoff makes no assertion that they compile or pass.

The independent reviewer should not silently repair these gaps before recording them.

## Source inventory

- `Sources/BudgetMacPersonal/App.swift`
- `Sources/BudgetMacPersonal/ApprovalView.swift`
- `Sources/BudgetMacPersonal/BudgetStore.swift`
- `Sources/BudgetMacPersonal/Models.swift`
- `Sources/BudgetMacPersonal/ReceiptVisionService.swift`
- `Sources/BudgetMacPersonal/SplitApprovalPolicy.swift`
- `Sources/BudgetMacPersonal/SubscriptionModels.swift`
- `Sources/BudgetMacPersonal/SubscriptionSchedule.swift`
- `Sources/BudgetMacPersonal/SubscriptionStore.swift`
- `Sources/BudgetMacPersonal/SubscriptionTracker.swift`
- `Sources/BudgetMacPersonal/SubscriptionView.swift`

## Existing test inventory

- `Tests/BudgetMacPersonalTests/ApprovalIntegrationTests.swift`
- `Tests/BudgetMacPersonalTests/BalanceValidationTests.swift`
- `Tests/BudgetMacPersonalTests/DraftEditingTests.swift`
- `Tests/BudgetMacPersonalTests/NegativeTransactionEdgeCaseTests.swift`
- `Tests/BudgetMacPersonalTests/RefundEdgeCaseTests.swift`
- `Tests/BudgetMacPersonalTests/RoundingEdgeCaseTests.swift`
- `Tests/BudgetMacPersonalTests/SplitApprovalTests.swift`
- `Tests/BudgetMacPersonalTests/SubscriptionReminderTests.swift`
- `Tests/BudgetMacPersonalTests/SubscriptionScheduleTests.swift`
- `Tests/BudgetMacPersonalTests/SubscriptionTrackerTests.swift`

The existing tests are prior development artefacts. The second reviewer should inspect them for correctness, duplication, false positives and whether assertions genuinely exercise production behaviour.

# Feature specification and current implementation

## 1. Transaction and receipt data models

`Models.swift` defines:

- `Transaction`: date, merchant, amount, fingerprint, approved splits and an optional pending split draft.
- `TransactionSplit`: label, category, amount and identifier.
- `ReceiptLineItem`: OCR/manual description, amount, category and confidence.
- `ReceiptRecord`: merchant, date, subtotal, tax, total, source image path, raw OCR text, line items, confidence and reviewed state.
- `SplitDraft`: a receipt plus proposed splits, created date, optional approval date and computed split total.
- `ChangeRecord`: transaction identifier, date and reason.

Key invariant to verify: a pending draft must not affect approved splits, reports or totals until approval.

## 2. Receipt OCR

`ReceiptVisionService.swift` uses:

- `NSImage` to load a user-selected image.
- `VNRecognizeTextRequest` with `.accurate` recognition.
- language correction and `en-GB`/`en-US` recognition languages.
- `VNImageRequestHandler` for local analysis.
- a parser that finds monetary values at the end of lines, excludes common total/tax/payment summary rows and creates candidate receipt items.

Current limitations to validate:

- No image picker is wired to the OCR service in the current entry point.
- OCR ordering, rotated receipts, perspective distortion, low contrast, multi-column layouts, discounts, coupons, quantities, decimal commas and multi-page invoices need independent assessment.
- The parser's regular expressions may misread totals, negative values, foreign currencies, thousands separators and text containing numbers.
- OCR confidence is not currently displayed or enforced by `ApprovalView`.

## 3. Manual receipt editing

`ApprovalView.swift` currently permits manual editing of:

- merchant;
- receipt date;
- receipt total;
- subtotal;
- VAT/tax;
- line-item description;
- line-item amount;
- line-item category.

The user can add or delete items. Categories are free-text in this view rather than constrained to a controlled category list.

## 4. Draft-only save

`BudgetStore.saveDraft` stores the `SplitDraft` in `Transaction.pendingSplitDraft`. It does not copy proposed lines into `Transaction.splits`.

Current limitations:

- `BudgetStore` is memory-only in this package. Drafts do not survive relaunch.
- `saveDraft` does not append a change-history record.
- No explicit copy-on-write or concurrency strategy exists.

Expected rule: saving a draft never changes approved spending allocations.

## 5. Balance validation and approval

There are two validation paths that should be reviewed for consistency:

- `ApprovalView` computes `balanced` using `Double` conversion and a `< 0.01` comparison.
- `SplitApprovalPolicy` uses `Decimal`, positive allocation magnitudes, the absolute bank-transaction amount and a default tolerance of `0.005`.

`SplitApprovalPolicy` requires:

- at least one proposed split;
- explicit manual review;
- non-empty descriptions;
- positive split values;
- a non-empty category that is not `Uncategorised`;
- absolute bank amount and split total to agree within tolerance.

Important review target: `ApprovalView` currently calls `BudgetStore.approve` directly, while `BudgetStore.approve` repeats only a basic difference check and does not call `SplitApprovalPolicy`. This creates policy drift and may allow approval behaviour to differ from the policy tests.

## 6. Approval commit

`BudgetStore.approve` currently:

1. finds the matching transaction;
2. checks absolute transaction amount against draft split total;
3. copies proposed splits into approved splits;
4. clears the pending draft;
5. appends a `ChangeRecord`;
6. updates a status string.

Current limitations:

- approval is not persisted to disk;
- `ChangeRecord` does not preserve before/after snapshots;
- approval is not transactional or crash-safe;
- approval does not independently confirm the `reviewed` flag;
- replacing existing approved splits is not separately audited;
- undo/redo is not implemented in this package.

## 7. Refunds and negative transactions

The intended representation is:

- negative bank transaction = purchase/debit;
- positive bank transaction = refund/credit;
- split allocations remain positive magnitudes in both cases;
- approval compares split total against `abs(bankAmount)`;
- negative split rows are invalid.

The reviewer should assess full refunds, partial refunds, mixed purchase/refund receipts, chargebacks, reversals, zero-value transactions and whether the positive-magnitude model is sufficient for reporting.

## 8. Decimal and rounding policy

`SplitApprovalPolicy` uses `Decimal` and a half-penny tolerance of `0.005`. Existing edge-case tests cover exact penny division, `0.10 + 0.20`, a half-penny boundary and values beyond that boundary.

Review whether a half-penny tolerance is appropriate for GBP, whether values should instead be normalised to integer pence, and whether OCR inputs with three decimal places should be accepted at all.

## 9. Subscription and contract model

`SubscriptionModels.swift` supports:

- vendor;
- type: streaming, broadband, cable, mobile, insurance, energy, utilities, software, membership or other;
- start date;
- minimum-term end date;
- renewal date;
- weekly, monthly, quarterly, six-monthly, yearly or custom billing;
- custom interval days;
- next payment due date;
- expected amount and currency;
- fixed, variable, introductory or unknown pricing;
- fixed-price end date;
- cancellation-notice days;
- account reference;
- notes;
- active, paused, cancelled or expired status;
- transaction matching terms.

Contract dates are manual fields. The system must not infer start, renewal, notice or fixed-price dates solely from bank transactions.

## 10. Subscription scheduling

`SubscriptionSchedule.swift`:

- advances dates via `Calendar` components;
- supports standard and custom billing periods;
- can advance the due date beyond a payment date;
- annualises the expected cost using 52 weekly, 12 monthly, 4 quarterly, 2 half-yearly or 1 yearly payments; custom periods use `365 / days`.

Review end-of-month handling, leap years, daylight-saving changes, 29 February annual contracts, missed payments and business-day adjustments.

## 11. Transaction-to-vendor matching

`SubscriptionTracker.matches` lowercases and concatenates merchant plus description, then performs substring matching against the vendor and optional aliases.

`payments` includes matching transactions only when `amount < 0`, then stores the absolute amount. Positive refunds and credits are excluded from paid totals.

Review risks:

- broad vendor names can create false matches;
- substring matching is not token-aware;
- no account/date/amount constraints;
- duplicate imported transactions would inflate totals;
- different contracts from the same vendor are not disambiguated;
- excluding refunds rather than netting them may overstate vendor cost.

## 12. Vendor summaries

`vendorSummary` reports:

- total paid;
- payment count;
- first payment;
- latest payment;
- average payment.

The summary is calculated from in-memory `Transaction` values supplied to `SubscriptionView`.

## 13. Due and renewal reminders

`dueSoon` returns active contracts whose next due date falls within the inclusive date window. `renewalSoon` does the same for renewal dates and ignores contracts that are not active.

Review contracts due exactly on the boundary, overdue contracts, time-of-day differences, locale/time-zone changes and paused/expired behaviour.

## 14. Subscription persistence

`SubscriptionStore` stores JSON at:

`~/Library/Application Support/BudgetMacPersonal/subscriptions.json`

It loads on initialisation and writes atomically when a contract is saved or deleted.

Review file permissions, corruption handling, schema migration, partial writes, symlink attacks, backup behaviour, sensitive account-reference storage and whether encryption is required for the personal threat model.

## 15. Subscription UI

`SubscriptionView` presents:

- add/edit contract;
- due-within-30-days count;
- renewals-within-60-days count;
- annual committed cost;
- vendor/type/next-payment/amount/renewal/paid-to-vendor table;
- contract editor for dates, billing period, pricing, notice period, match terms and notes.

Current limitation: the view is not wired into `App.swift`.

# Suggested independent functional test charter

The second reviewer should design tests independently. At minimum, validate:

- compilation under the selected latest stable Xcode and installed macOS SDK;
- empty launch and seeded launch;
- OCR input handling for valid and malformed images;
- draft editing, save, reopen and loss on relaunch;
- approval policy versus UI/store behaviour;
- replacement of previously approved splits;
- refunds, debits, rounding and zero amounts;
- duplicate transaction handling;
- contract CRUD and persistence;
- monthly dates on 28/29/30/31;
- leap-year renewals;
- custom interval validation;
- overdue and exact-boundary reminders;
- multiple contracts with one vendor;
- aliases, false positives and case/whitespace variations;
- refunds and credits in vendor totals;
- JSON corruption and incompatible schema;
- accessibility, keyboard navigation, VoiceOver labels and Dynamic Type equivalents for macOS;
- performance with large transaction and contract collections.

# Security review charter

## Static analysis

- Compile with warnings enabled and review all warnings.
- Run SwiftLint or equivalent rules if installed, but record the ruleset.
- Search for `Process`, `NSTask`, shell execution, dynamic loading, clear-text HTTP, unsafe deserialisation, force unwraps and ignored errors.
- Scan for API keys, passwords, tokens, account numbers, card numbers, sort codes, IBANs, addresses and copied statement data.
- Check whether fixtures or logs expose real financial information.

## Dependency and supply-chain review

- Inspect `Package.swift` and `Package.resolved`.
- Confirm whether the package has any external dependencies. The current manifest declares none.
- Review build scripts for network access or arbitrary command execution.
- Record the exact Xcode, Swift and SDK versions used.

## Local-data protection

- Inspect file locations and permissions.
- Test malicious symlinks and pre-existing files at the Application Support path.
- Test malformed and oversized JSON.
- Confirm atomic-write behaviour.
- Determine whether account references, OCR text and receipt images require encryption at rest.
- Confirm sensitive data is not written to Console logs, crash messages or test output.

## Receipt-input security

- Test huge images, decompression bombs, corrupted files, unsupported formats, rotated images and files renamed with image extensions.
- Apply size and pixel-count limits before decoding.
- Check memory and CPU exhaustion.
- Verify security-scoped URL handling if App Sandbox is enabled later.
- Confirm OCR remains local and no data is sent over the network.

## Integrity and authorisation

- Attempt approval without the review declaration.
- Attempt approval through the store while bypassing the UI.
- Attempt unbalanced, empty, uncategorised, negative and duplicate splits.
- Attempt replacement of existing splits without an adequate audit record.
- Test concurrent saves and approvals.
- Test crash/relaunch between draft save and approval.

## Privacy

- Treat statements and receipts as highly sensitive personal financial records.
- Do not upload real statements to third-party scanning services.
- Use synthetic fixtures wherever possible.
- Redact names, addresses, account identifiers and transaction references in reports.

# Statement-derived validation scenarios

The attached statements demonstrate why the reviewer should test several transaction forms:

- repeating merchant debits such as Spotify, Vodafone, ID Mobile, Virgin Media, Octopus Energy and insurance payments;
- card repayments that must not be counted as spending;
- positive credits marked `CR` that may represent refunds or payments;
- recurring card authorities and Direct Debits;
- separate transaction and processing dates;
- foreign-currency entries and related fees;
- duplicate copies of a statement;
- different bank layouts and amount-column conventions.

Do not copy real account numbers, addresses or card numbers into fixtures or issue reports.

# Required review report format

Ask the second reviewer to return:

1. **Environment**: hardware/architecture, macOS, Xcode, Swift and SDK versions.
2. **Build result**: exact commands, exit codes and full error summary.
3. **Existing tests**: discovered, compiled, passed, failed and skipped counts.
4. **New tests**: files created and behaviours covered.
5. **Functional findings**: severity, reproduction, expected behaviour, actual behaviour and fix.
6. **Security findings**: severity, CWE where applicable, exploitability, evidence and remediation.
7. **Privacy findings**: data collected, storage path, retention, logging and transmission.
8. **Architecture findings**: missing integration, duplicate validation paths and persistence gaps.
9. **Residual risks**: anything not tested and why.
10. **Final verdict**: prototype, development-ready, beta-ready or release-ready, with explicit blockers.

# Recommended commands for the reviewer

Run commands appropriate to the review Mac and record complete output:

```bash
xcodebuild -version
swift --version
xcode-select -p
xcodebuild -showsdks
swift package describe
swift package resolve
swift test --parallel
```

Also inspect the source manually before changing it. Do not treat a passing ZIP integrity check as build validation.

# iPhone support added

The package now declares iOS 17 and macOS 14. `AdaptiveRootView` uses a five-tab iPhone interface and a sidebar on macOS. iPhone receipt capture supports PhotosPicker and UIImagePickerController camera capture, then runs local Apple Vision OCR. The mobile tabs are Overview, Transactions, Budgets, Recurring and Review. Contract editing, local JSON persistence, receipt draft approval and responsive transaction editing are included. The independent reviewer must verify camera permissions, iPhone simulator/device build, orientation, Dynamic Type, VoiceOver, privacy strings and persistence migration.
