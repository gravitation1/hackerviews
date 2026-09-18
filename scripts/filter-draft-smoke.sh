#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 \
  HackerViews/Core/*.swift HackerViews/Views/*.swift HackerViews/Browser/*.swift \
  HackerViews/RecordStore.swift HackerViews/Sync/CloudSync.swift Tests/NativeUI/FilterDraftSmoke.swift \
  -o "$output/FilterDraftSmoke"
"$output/FilterDraftSmoke"
