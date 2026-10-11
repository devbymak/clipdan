#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/module-cache
clipdan_cache_path="$(cd .build/module-cache && pwd -P)"
xcrun swiftc -target arm64-apple-macosx13.0 -module-cache-path "$clipdan_cache_path" -swift-version 5 sources/clips.swift tests/main.swift -o .build/clip-tests
.build/clip-tests
