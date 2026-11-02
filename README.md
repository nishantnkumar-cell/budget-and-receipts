# Duo Budget

A private budgeting and receipt app for one person or a couple, for iPhone and Mac, with a Windows version planned. Receipts are read on the device with Apple Vision; nothing leaves the device by default.

## Layout

| Folder | What it holds |
| --- | --- |
| `Core/` | `BudgetCore` Swift package: models and money rules (split approval, contracts, receipt parsing). Foundation only, so it also builds on Linux and Windows. |
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
