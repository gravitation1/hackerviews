#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift test
npm test
xcodebuild -quiet -project QuietHN.xcodeproj -scheme QuietHN \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project QuietHN.xcodeproj -scheme QuietHN -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios CODE_SIGNING_ALLOWED=NO build
