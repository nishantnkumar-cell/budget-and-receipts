#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
swift test --parallel
