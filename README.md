# Duo Budget

A private budgeting and receipt app for one person or a couple, for iPhone and Mac. Receipts are read on the device with Apple Vision and Apple Intelligence, and data stays on your devices and in end-to-end encrypted iCloud.

Duo Budget is open source under the [MIT licence](LICENSE). It is also sold on the App Store, where the price pays for the signed, updated build; see [docs/RELEASING.md](docs/RELEASING.md). Privacy policy: [docs/PRIVACY.md](docs/PRIVACY.md).

## Features

**Getting money in**
- Import CSV, OFX, QFX, QIF and PDF statements (including HSBC), or share them into the app. The bank, account and account holder are read from the statement, and re-importing never adds a payment twice.
- Several bank accounts and cards, kept apart, with card endings so receipts match the right account.
- Automatic categories from 50 starter rules, your own rules and on-device Apple Intelligence, with an optional Apple Maps lookup for unknown shops.
- Log Apple Pay payments as you tap, through a Shortcuts automation; they merge with the statement line later.

**Receipts**
- Scan, pick or share receipts. They're read on the device with Apple Vision and Apple Intelligence.
- Receipts wait for their payment and are matched only when exactly one payment has the same total, from 2 days before to 7 days after the receipt. You check the items next to the photo, then approve the split.
- Return-by and warranty dates, with reminders.

**Budgets and planning**
- Monthly budgets per category and sub-category, with a 3-month average as a "Tentative" budget, rollover, payday-to-payday months and "Safe to spend today".
- Subscriptions and contracts tracked separately: next payments, renewals, notice deadlines, fixed-price ends, contract documents and reminders.
- Savings goals, trips with exchange rates and card fees, and money owed back to you.
- Tags and expense reports.

**For couples**
- Invite a partner with a QR code or link. Everything is shared unless marked private, and stays end-to-end encrypted.
- Mine, Partner or Shared on every payment and receipt item, with merchant and category rules, a Me / Partner / Together switch, income-based shares and who owes whom.

**Seeing the big picture**
- Reports: cash flow, trends, shops, whose spending, your year, exported as PDF or CSV.
- Net worth with savings, pensions, property and mortgages; pensions and property count in the total but are shown apart.
- Home and Lock Screen widgets, a Control Centre scan button, Siri and Shortcuts, and "Ask your budget" answered on the device.
- A Mac command centre with ⌘K to jump anywhere.

**Privacy and safety**
- No account, no servers, no analytics. Data stays on your devices and in end-to-end encrypted iCloud.
- Face ID, Touch ID or passcode lock; password-encrypted backup files and restore; Erase All Data behind Face ID and typing ERASE.

## User guides

Plain-language guides for people using the app are in [docs/guides](docs/guides/README.md): first setup, importing statements, receipts, budgets, subscriptions and contracts, couples, reports, goals and trips, widgets and Siri, backups, and privacy.

## Layout

| Folder | What it holds |
| --- | --- |
| `Core/` | `BudgetCore` Swift package: models and money rules (split approval, contracts, receipt parsing). Foundation only, so its tests also run on Linux. |
| `Apple/` | iPhone and Mac apps. `project.yml` is the XcodeGen spec; the `.xcodeproj` is generated and not committed. |
| `Apple/Shared/` | SwiftUI screens, stores, iCloud sync and the Vision OCR service shared by both apps. |
| `Apple/Widgets/` | Home Screen, Lock Screen and Control Centre widgets. |
| `Apple/ShareExtension/` | Share receipts and statements into the app from other apps. |
| `Fixtures/` | Synthetic bank statements (CSV, OFX, QIF) that the tests must read the same way. |
| `docs/guides/` | User guides. |
| `docs/design/` | Design notes for each feature, for contributors. |
| `docs/PRIVACY.md`, `docs/RELEASING.md` | Privacy policy and the App Store release steps. |

## Build and test (Mac)

Requires Xcode 26 or later and XcodeGen (`brew install xcodegen`).

```bash
Scripts/verify.command
```

Or step by step:

```bash
cd Core && swift test
cd ../Apple && xcodegen generate && open BudgetReceipts.xcodeproj
```

To put the app on your iPhone, plug it in, unlock it and run:

```bash
Scripts/install-iphone.command
```

Builds are signed with the Apple Developer team set in `Apple/project.yml` (`DEVELOPMENT_TEAM`).

Minimum OS: iOS 26 and macOS 26, for the on-device Apple Intelligence features.

## Money rules

- Amounts are `Decimal`. In tests, write money as `money("3.69")`, never as the literal `3.69`, which goes through floating point.
- A receipt split is only applied after `SplitApprovalPolicy` passes: reviewed, every line has a description, a category and a positive amount, and the total is within half a penny of the bank amount.

## Releasing

`Scripts/testflight.command` archives both apps and uploads them to TestFlight. The one-time App Store Connect, iCloud and pricing steps are in [docs/RELEASING.md](docs/RELEASING.md).

## Licence

The code is under the [MIT licence](LICENSE): you may use, change and share it, including in your own apps. The name "Duo Budget" and the app icon and logo in `Design/logo/` and `Apple/Shared/Assets.xcassets/AppIcon.appiconset/` identify the official app and are not licensed for use in other published apps. Please give your own build a different name and icon before publishing it.
