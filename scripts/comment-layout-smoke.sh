#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 Tests/NativeUI/CommentLayoutSmoke.swift -o "$output/CommentLayoutSmoke"
"$output/CommentLayoutSmoke"
