#!/bin/sh
# Builds Monoword.app with only the Command Line Tools: swift build (release), then assembles the
# bundle (Info.plist stamped with the commit, icon, executable) and signs it with the project's
# stable identity (scripts/make-signing-identity.sh) so the Accessibility permission survives
# rebuilds; ad hoc if that identity does not exist or MONOWORD_ADHOC=1. MONOWORD_UNIVERSAL=1 builds
# one binary for Apple silicon and Intel.
# Output: build/Monoword.app (MONOWORD_BUILD_DIR puts it elsewhere).
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="${MONOWORD_BUILD_DIR:-$ROOT/build}"
APP="$OUT/Monoword.app"
mkdir -p "$OUT" "$ROOT/.trash"

# Uncommitted local extensions (Sources/*/Local, gitignored) are switched on only when present.
LOCAL=""
if [ -d Sources/MonowordApp/Local ]; then LOCAL="-Xswiftc -DLOCAL_EXTENSIONS"; fi
# The app, and monoword-schedule (the reader's timetable for a text, which the Claude Code plugin's
# strip runs from inside the bundle).
if [ -n "$MONOWORD_UNIVERSAL" ]; then
  # One app for Apple silicon and Intel Macs (for downloads).
  for arch in arm64 x86_64; do
    swift build -c release --product Monoword --triple $arch-apple-macosx14.0 $LOCAL
    swift build -c release --product monoword-schedule --triple $arch-apple-macosx14.0 $LOCAL
  done
  BIN="$ROOT/.build/Monoword-universal"
  lipo -create -output "$BIN" "$ROOT/.build/arm64-apple-macosx/release/Monoword" \
    "$ROOT/.build/x86_64-apple-macosx/release/Monoword"
  TOOL="$ROOT/.build/monoword-schedule-universal"
  lipo -create -output "$TOOL" "$ROOT/.build/arm64-apple-macosx/release/monoword-schedule" \
    "$ROOT/.build/x86_64-apple-macosx/release/monoword-schedule"
else
  swift build -c release --product Monoword $LOCAL
  swift build -c release --product monoword-schedule $LOCAL
  BINDIR="$(swift build -c release --product Monoword $LOCAL --show-bin-path)"
  BIN="$BINDIR/Monoword"
  TOOL="$BINDIR/monoword-schedule"
fi

# Icon: drawn by scripts/make-icon.swift (no binary assets in the repo), cached in build/.
ICNS="$ROOT/build/AppIcon.icns"
if [ ! -f "$ICNS" ]; then
  mkdir -p "$ROOT/build"
  ICONSET="$ROOT/build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$ROOT/build/icon-1024.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/build/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ROOT/build/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
fi

# Assemble into a staging bundle, then swap it in, so a failed build never leaves half an app.
STAGE="$OUT/.Monoword.app.staging"
if [ -e "$STAGE" ]; then mv "$STAGE" "$ROOT/.trash/Monoword.app.staging.$(date +%s)"; fi
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp App/Info.plist "$STAGE/Contents/Info.plist"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT+"; fi
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || echo 1)
plutil -replace SRBuildCommit -string "$COMMIT" "$STAGE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$STAGE/Contents/Info.plist"
cp "$ICNS" "$STAGE/Contents/Resources/AppIcon.icns"
cp Resources/word-frequency-en.txt "$STAGE/Contents/Resources/word-frequency-en.txt"
cp "$BIN" "$STAGE/Contents/MacOS/Monoword"
strip -x "$STAGE/Contents/MacOS/Monoword"
cp "$TOOL" "$STAGE/Contents/MacOS/monoword-schedule"
strip -x "$STAGE/Contents/MacOS/monoword-schedule"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# The tool is signed first, then the bundle that seals it (nested code is signed inside out).
SIGN_KC="$ROOT/.signing/signing.keychain-db"
if [ -f "$SIGN_KC" ] && [ -z "$MONOWORD_ADHOC" ]; then
  security unlock-keychain -p "$(cat "$ROOT/.signing/keychain-password")" "$SIGN_KC"
  # The only certificate in that keychain file (scripts/make-signing-identity.sh).
  IDENTITY=$(security find-certificate -a -Z "$SIGN_KC" | awk '/SHA-1 hash/ {print $3; exit}')
  # codesign only finds identities in keychains on the user search list: add ours for the signing
  # step only, then put the list back exactly as it was (also on failure).
  KC_BEFORE=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//')
  restore_kc() { echo "$KC_BEFORE" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s; }
  trap restore_kc EXIT
  { echo "$KC_BEFORE"; echo "$SIGN_KC"; } | tr '\n' '\0' | xargs -0 security list-keychains -d user -s
  codesign --force --sign "$IDENTITY" --keychain "$SIGN_KC" --timestamp=none "$STAGE/Contents/MacOS/monoword-schedule"
  codesign --force --sign "$IDENTITY" --keychain "$SIGN_KC" --timestamp=none "$STAGE"
  restore_kc; trap - EXIT
else
  codesign --force --sign - --timestamp=none "$STAGE/Contents/MacOS/monoword-schedule"
  codesign --force --sign - --timestamp=none "$STAGE"
fi
if [ -e "$APP" ]; then mv "$APP" "$ROOT/.trash/Monoword.app.$(date +%s)"; fi
mv "$STAGE" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1), commit $COMMIT)"
