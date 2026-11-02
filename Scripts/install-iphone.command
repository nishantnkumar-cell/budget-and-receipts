#!/bin/zsh
# Builds a signed copy of the iPhone app and installs it on a connected iPhone.
# Plug the phone in (or have it on the same Wi-Fi with "Connect via network" on), unlock it,
# and turn on Developer Mode the first time (Settings › Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")/.."
(cd Apple && xcodegen generate)

DEVICE=${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && !/unavailable/ {for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)}
if [[ -z "$DEVICE" ]]; then
  echo "No iPhone is connected. Plug it in, unlock it and try again."
  exit 1
fi

DERIVED=.build/DeviceData
xcodebuild -project Apple/BudgetReceipts.xcodeproj -scheme BudgetReceipts-iOS \
  -destination "id=$DEVICE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates build
APP=$(ls -d "$DERIVED"/Build/Products/Debug-iphoneos/*.app | head -1)
xcrun devicectl device install app --device "$DEVICE" "$APP"
echo "Installed on your iPhone."
