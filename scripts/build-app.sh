#!/usr/bin/env bash
# Builds "build/Ember Mail.app" with swiftc directly (SwiftPM is broken in the installed
# Command Line Tools, and the default SDK is newer than the compiler — so we pin the SDK).
#   ./scripts/build-app.sh            release build
#   ./scripts/build-app.sh --debug    debug build (faster compile)
#   ./scripts/build-app.sh --install  also copy to ~/Applications
#   ./scripts/build-app.sh --run      build and launch
#   ./scripts/build-app.sh --version 1.2.0   stamp the app version (release.sh does this)
# Env: EMBER_SIGN_ID="Developer ID Application: Name (TEAMID)" signs with that identity + hardened runtime.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release; INSTALL=0; RUN=0; VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG=debug ;;
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    --version) VERSION="$2"; shift ;;
  esac
  shift
done

SDK_DIR=/Library/Developer/CommandLineTools/SDKs
SDK="${EMBER_SDK:-}"
if [ -z "$SDK" ]; then
  for candidate in MacOSX26.5.sdk MacOSX26.sdk MacOSX15.sdk; do
    if [ -d "$SDK_DIR/$candidate" ]; then SDK="$SDK_DIR/$candidate"; break; fi
  done
fi
[ -z "$SDK" ] && SDK=$(xcrun --show-sdk-path)

OUT=build
APP="$OUT/Ember Mail.app"
mkdir -p "$OUT"

FLAGS=(-parse-as-library -target arm64-apple-macos14.0 -sdk "$SDK" -module-name EmberMail)
if [ "$CONFIG" = release ]; then FLAGS+=(-O -whole-module-optimization); else FLAGS+=(-Onone -g); fi

echo "▸ Compiling ($CONFIG, SDK: $(basename "$SDK"))"
# shellcheck disable=SC2046
rm -f "$OUT/EmberMail"
if ! swiftc "${FLAGS[@]}" $(find Sources/EmberMail -name '*.swift' | tr '\n' ' ') -o "$OUT/EmberMail" > "$OUT/build.log" 2>&1; then
  grep -E "error:" "$OUT/build.log" | sort -u
  echo "✗ Build failed (full log: $OUT/build.log)"; exit 1
fi

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Generating app icon"
  swift -sdk "$SDK" scripts/make-icon.swift Resources/AppIcon.icns
fi

echo "▸ Bundling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$OUT/EmberMail" "$APP/Contents/MacOS/EmberMail"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable identity (scripts/setup-signing.sh) keeps the signature identical across builds, so macOS
# remembers Keychain "Always Allow". Without it we fall back to ad-hoc signing.
if [ -n "${EMBER_SIGN_ID:-}" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$EMBER_SIGN_ID" "$APP"
  echo "  signed with \"$EMBER_SIGN_ID\" (hardened runtime)"
else
SIGN_ID="Ember Mail Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID" \
   && codesign --force --deep --timestamp=none --sign "$SIGN_ID" "$APP" >/dev/null 2>&1; then
  echo "  signed with \"$SIGN_ID\""
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "  ad-hoc signed — run ./scripts/setup-signing.sh once to stop Keychain prompts after updates"
fi
fi
echo "✓ Built $APP"

if [ "$INSTALL" = 1 ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Ember Mail.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "✓ Installed to ~/Applications/Ember Mail.app"
fi
if [ "$RUN" = 1 ]; then open "$APP"; fi
