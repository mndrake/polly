#!/usr/bin/env bash
# Builds Polly.app from the Swift package.
#
#   scripts/build-app.sh                 # release build, ad-hoc signed, ./build/Polly.app
#   SIGN_IDENTITY="Developer ID Application: Jane Doe (TEAMID)" scripts/build-app.sh
#   CONFIGURATION=debug scripts/build-app.sh
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT_DIR="${OUT_DIR:-build}"
APP="$OUT_DIR/Polly.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product Polly ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIGURATION" --product Polly ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Polly" "$APP/Contents/MacOS/Polly"
# SwiftPM resource bundles from dependencies (e.g. FluidAudio) live next to
# the binary; Bundle.module finds them in Contents/Resources.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done
cp App/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing with identity '$SIGN_IDENTITY'…"
codesign --force --options runtime \
  --entitlements App/Polly.entitlements \
  --sign "$SIGN_IDENTITY" \
  "$APP"
codesign --verify --verbose=2 "$APP"

if [[ "${ZIP:-0}" == "1" ]]; then
  # ditto preserves the bundle's permissions, symlinks and signature.
  ditto -c -k --keepParent "$APP" "$OUT_DIR/Polly.zip"
  echo "✓ Zipped $OUT_DIR/Polly.zip"
fi

echo "✓ Built ${APP}"
echo "  Run it with: open \"$APP\""
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "  (Ad-hoc signed: macOS may ask for permissions again after each rebuild.)"
fi
