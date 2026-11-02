#!/bin/zsh
# Builds and tests everything on a Mac: the shared core, then the Mac and iPhone apps.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version

echo "== BudgetCore tests"
(cd Core && swift test --parallel)

echo "== Generate Xcode project"
(cd Apple && xcodegen generate)

DERIVED=.build/DerivedData
echo "== macOS app tests"
# Signed with the development team: the Mac app's iCloud entitlements need a real certificate.
xcodebuild -project Apple/BudgetReceipts.xcodeproj -scheme BudgetReceipts-macOS \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" -allowProvisioningUpdates test

echo "== iOS app tests"
SIMULATOR=${SIMULATOR:-"iPhone 17"}
xcodebuild -project Apple/BudgetReceipts.xcodeproj -scheme BudgetReceipts-iOS \
  -destination "platform=iOS Simulator,name=$SIMULATOR" -derivedDataPath "$DERIVED" test
