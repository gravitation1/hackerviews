#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift test
npm test
xcodebuild -project HackerViews.xcodeproj -scheme HackerViews \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project HackerViews.xcodeproj -scheme HackerViews -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios CODE_SIGNING_ALLOWED=NO build
