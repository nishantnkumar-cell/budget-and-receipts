# Duo Budget

A private budgeting and receipt app for one person or a couple, for iPhone and Mac. Receipts are read on the device with Apple Vision and Apple Intelligence, and data stays on your devices and in end-to-end encrypted iCloud.

Duo Budget is open source under the [MIT licence](LICENSE). It is also sold on the App Store, where the price pays for the signed, updated build; see [docs/RELEASING.md](docs/RELEASING.md). Privacy policy: [docs/PRIVACY.md](docs/PRIVACY.md).

## Layout

| Folder | What it holds |
| --- | --- |
| `Core/` | `BudgetCore` Swift package: models and money rules (split approval, contracts, receipt parsing). Foundation only, so its tests also run on Linux. |
| `Apple/` | iPhone and Mac apps. `project.yml` is the XcodeGen spec; the `.xcodeproj` is generated and not committed. |
| `Apple/Shared/` | SwiftUI screens, stores and the Vision OCR service shared by both apps. |
| `Fixtures/` | Synthetic bank statements (CSV, OFX, QIF) that every platform's tests must read the same way. |
| `docs/design/` | Feature notes from the original prototype. |

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

Minimum OS: iOS 26 and macOS 26, so the on-device Apple Intelligence features can be added.

## Money rules

- Amounts are `Decimal`. In tests, write money as `money("3.69")`, never as the literal `3.69`, which goes through floating point.
- A receipt split is only applied after `SplitApprovalPolicy` passes: reviewed, every line has a description, a category and a positive amount, and the total is within half a penny of the bank amount.

## Releasing

`Scripts/testflight.command` archives both apps and uploads them to TestFlight. The one-time App Store Connect, iCloud and pricing steps are in [docs/RELEASING.md](docs/RELEASING.md).

## Licence

The code is under the [MIT licence](LICENSE): you may use, change and share it, including in your own apps. The name "Duo Budget" and the app icon and logo in `Design/logo/` and `Apple/Shared/Assets.xcassets/AppIcon.appiconset/` identify the official app and are not licensed for use in other published apps. Please give your own build a different name and icon before publishing it.
