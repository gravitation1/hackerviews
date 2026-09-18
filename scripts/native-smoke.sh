#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
bundle="$PWD/build/NativeSmoke.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp HackerViews/Resources/filter.js "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>NativeSmoke</string><key>CFBundleIdentifier</key><string>com.local.HackerViews.NativeSmoke</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
EOF
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 \
  HackerViews/Core/*.swift HackerViews/RecordStore.swift HackerViews/Sync/CloudSync.swift \
  HackerViews/Browser/BrowserTab.swift HackerViews/Browser/HNService.swift Tests/NativeSmoke.swift \
  -o "$bundle/Contents/MacOS/NativeSmoke"
"$bundle/Contents/MacOS/NativeSmoke" "$@"
