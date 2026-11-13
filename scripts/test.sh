#!/usr/bin/env bash
# Compiles the UI-free code with Tests/main.swift and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${EMBER_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
mkdir -p build
swiftc -target arm64-apple-macos14.0 -sdk "$SDK" -module-name EmberMailTests \
  $(find Sources/EmberMail/Models Sources/EmberMail/Services -name '*.swift') Tests/main.swift \
  -o build/tests > build/test-build.log 2>&1 || { grep error: build/test-build.log; exit 1; }
./build/tests
