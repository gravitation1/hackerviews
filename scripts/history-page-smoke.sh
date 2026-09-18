#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 \
  HackerViews/Core/*.swift HackerViews/Views/*.swift HackerViews/Browser/*.swift \
  HackerViews/RecordStore.swift HackerViews/Sync/CloudSync.swift Tests/NativeUI/HistoryPageSmoke.swift \
  -o "$output/HistoryPageSmoke"
# Keep the fixture entirely local, including canonical metadata fetches.
python3 - "$output/filter.js" <<'PY'
import sys
source = open('HackerViews/Resources/filter.js').read()
source = source.replace('  async function loadVoteActions() {', '  async function loadVoteActions() { return;')
open(sys.argv[1], 'w').write(source)
PY
"$output/HistoryPageSmoke"
