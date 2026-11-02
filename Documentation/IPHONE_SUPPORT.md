# iPhone support

## User interface
- Five-tab SwiftUI interface: Overview, Transactions, Budgets, Recurring and Review.
- NavigationStack detail flows, searchable transactions, swipe-to-delete, compact money cards and accessible system symbols.
- Adaptive macOS sidebar remains available.

## Mobile receipt flow
- Choose an image with PhotosPicker or capture with the camera.
- Run Apple Vision OCR locally.
- Edit merchant, total, line descriptions, amounts and categories.
- Save as draft or approve after manual review and balance validation.

## Local data
Transactions, budgets, imports and contracts use JSON files in Application Support. No bank login, advertising or telemetry is added.

## Xcode integration note
A Swift Package can build the shared source, but camera use and distribution require an iOS app target with an Info.plist camera usage description, signing team and bundle identifier. The second-pair reviewer should create/verify that target in Xcode and test on a physical iPhone.
