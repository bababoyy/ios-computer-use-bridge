#!/usr/bin/env bash
# Dylib'i iOS (arm64) için derler. macOS + Xcode gerektirir (CI'da çalışır).
# Çıktı: build/ComputerUseBridge.dylib
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=build
OUT="$OUT_DIR/ComputerUseBridge.dylib"
MIN_IOS="${MIN_IOS:-26.0}"

mkdir -p "$OUT_DIR"

echo "SDK: $(xcrun --sdk iphoneos --show-sdk-version)  min iOS: $MIN_IOS"

xcrun --sdk iphoneos clang \
  -arch arm64 \
  -mios-version-min="$MIN_IOS" \
  -dynamiclib \
  -fobjc-arc \
  -O2 \
  -Wall -Wextra -Wno-unused-parameter -Werror \
  -install_name "@executable_path/Frameworks/ComputerUseBridge.dylib" \
  -framework Foundation \
  -framework UIKit \
  -framework CoreGraphics \
  -framework Network \
  -weak_framework WebKit \
  -o "$OUT" \
  dylib/src/*.m

# Ad-hoc imza; asıl imza IPA yeniden imzalanırken atılır.
codesign --force --sign - "$OUT"

file "$OUT"
otool -L "$OUT"
