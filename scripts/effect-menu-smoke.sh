#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 \
  QuietHN/Core/*.swift QuietHN/Views/*.swift QuietHN/Browser/*.swift \
  QuietHN/RecordStore.swift QuietHN/Sync/CloudSync.swift Tests/NativeUI/EffectMenuSmoke.swift \
  -o "$output/EffectMenuSmoke"
"$output/EffectMenuSmoke"
