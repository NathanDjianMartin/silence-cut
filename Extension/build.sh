#!/bin/bash
# Build SilenceCut.app (host app + FCP Workflow Extension) with Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"
SDK=/Library/Developer/SDKs/WorkflowExtensionSDK.sdk
OUT=build/SilenceCut.app
rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/PlugIns/SilenceCutExt.appex/Contents/MacOS"

swiftc -O -target arm64-apple-macos26.0 -o "$OUT/Contents/MacOS/SilenceCut" App/main.swift
cp App.plist "$OUT/Contents/Info.plist"

APPEX="$OUT/Contents/PlugIns/SilenceCutExt.appex"
swiftc -O -target arm64-apple-macos26.0 -application-extension -parse-as-library \
  -module-name SilenceCutExt \
  -F "$SDK/Library/Frameworks" -L "$SDK/usr/lib" -lProExtension \
  -Xlinker -e -Xlinker _ProExtensionMain \
  -Xlinker -rpath -Xlinker "/Applications/Final Cut Pro.app/Contents/Frameworks" \
  -framework ProExtensionHost -framework Speech -import-objc-header Bridging-Header.h -Xcc -I"$SDK/usr/include" \
  -o "$APPEX/Contents/MacOS/SilenceCutExt" Sources/*.swift
cp Extension.plist "$APPEX/Contents/Info.plist"

IDENTITY="${IDENTITY:--}"
codesign --force --sign "$IDENTITY" --entitlements Extension.entitlements "$APPEX"
codesign --force --sign "$IDENTITY" "$OUT"
echo "OK -> $OUT"
