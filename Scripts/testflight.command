#!/bin/zsh
# Archives the iPhone and Mac apps and uploads both to App Store Connect for TestFlight.
# Needs Xcode signed in to the Apple Developer account (Xcode › Settings › Accounts) and the
# app created in App Store Connect. Usage: Scripts/testflight.command [ios|macos]   (default: both)
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version

# Every upload needs a higher build number than the last: use the date and time (UTC).
BUILD=$(date -u +%Y%m%d.%H%M)
echo "== Build number $BUILD"

(cd Apple && xcodegen generate)

OUT=.build/testflight/$BUILD
mkdir -p "$OUT"
PLATFORMS=(${1:-ios macos})

for platform in $PLATFORMS; do
  case $platform in
    ios)   scheme=BudgetReceipts-iOS;   destination="generic/platform=iOS" ;;
    macos) scheme=BudgetReceipts-macOS; destination="generic/platform=macOS" ;;
    *) echo "Unknown platform: $platform (use ios or macos)"; exit 1 ;;
  esac
  echo "== Archive $scheme"
  xcodebuild archive -project Apple/BudgetReceipts.xcodeproj -scheme "$scheme" \
    -configuration Release -destination "$destination" \
    -archivePath "$OUT/$scheme.xcarchive" -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD"
  echo "== Upload $scheme"
  xcodebuild -exportArchive -archivePath "$OUT/$scheme.xcarchive" \
    -exportOptionsPlist Scripts/ExportOptions.plist -exportPath "$OUT/$scheme" \
    -allowProvisioningUpdates
done

echo "Uploaded build $BUILD. It appears in App Store Connect › TestFlight after Apple has processed it (usually 10 to 30 minutes)."
