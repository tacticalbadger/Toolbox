#!/usr/bin/env bash
# Builds the app with SwiftPM (Command Line Tools are enough; no Xcode
# license needed) and wraps the binary in build/Toolbox.app.
#
#   CONFIG=debug|release   (default debug)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
APP="$ROOT/build/Toolbox.app"
unset DEVELOPER_DIR
# Where updates come from and the key they are checked against.
source "$ROOT/bridge/update-config.sh"

# The Command Line Tools lack SwiftUI's macro plugin; borrow Xcode's copy.
SWIFT_FLAGS=()
XCODE_PLUGINS="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
if [[ -d "$XCODE_PLUGINS" ]]; then
  SWIFT_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$XCODE_PLUGINS")
fi

# A release must not name this Mac: `#file` in Swift (and in the packages
# built with it) would otherwise carry the checkout's path into the binary.
if [[ "$CONFIG" == "release" ]]; then
  SWIFT_FLAGS+=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=/toolbox" -Xcc "-ffile-prefix-map=$ROOT=/toolbox")
fi

# Code signing. The Keychain remembers "Always Allow" per code signature and
# an ad-hoc signature changes with every build, so prefer a real identity:
#   TOOLBOX_SIGN_IDENTITY=<name or SHA-1>   explicit choice
#   otherwise the first of: Developer ID Application, Apple Development,
#   Toolbox Local Signing (from `make signing`); ad hoc as a last resort.
pick_identity() {
  local identities pattern line
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ -n "${TOOLBOX_SIGN_IDENTITY:-}" ]]; then
    # An explicit choice may be a SHA-1 or a name; look up its full name so
    # the Developer ID options below (timestamp, hardened runtime) apply.
    line="$(printf '%s\n' "$identities" | grep -F "$TOOLBOX_SIGN_IDENTITY" | head -1 || true)"
    if [[ -n "$line" ]]; then
      printf '%s\t%s\n' "$TOOLBOX_SIGN_IDENTITY" "$(sed -E 's/^[^"]*"(.*)"[^"]*$/\1/' <<<"$line")"
    else
      printf '%s\t%s\n' "$TOOLBOX_SIGN_IDENTITY" "$TOOLBOX_SIGN_IDENTITY"
    fi
    return
  fi
  for pattern in "Developer ID Application:" "Apple Development:" "Toolbox Local Signing"; do
    line="$(printf '%s\n' "$identities" | grep -F "$pattern" | head -1 || true)"
    if [[ -n "$line" ]]; then
      # lines look like:  1) <sha1> "<name>"
      printf '%s\t%s\n' "$(awk '{print $2}' <<<"$line")" "$(sed -E 's/^[^"]*"(.*)"[^"]*$/\1/' <<<"$line")"
      return
    fi
  done
  printf -- '-\tad-hoc\n'
}
IFS=$'\t' read -r SIGN_ID SIGN_NAME < <(pick_identity)
SIGN_FLAGS=(--force --sign "$SIGN_ID")
# TOOLBOX_HARDENED=1 (set by `make release`) asks for what notarization
# needs: the hardened runtime, plus Apple's secure timestamp when signing
# with a Developer ID. Everyday builds skip both: they then need no network
# and stay debuggable, while keeping the same identity, so the Keychain's
# "Always Allow" covers development and release builds alike.
if [[ "${TOOLBOX_HARDENED:-0}" == "1" ]]; then
  SIGN_FLAGS+=(--options runtime)
fi
case "$SIGN_NAME" in
  ad-hoc) ;;
  *"Developer ID Application"*)
    if [[ "${TOOLBOX_HARDENED:-0}" == "1" ]]; then SIGN_FLAGS+=(--timestamp); else SIGN_FLAGS+=(--timestamp=none); fi ;;
  *) SIGN_FLAGS+=(--timestamp=none) ;;
esac

# Versions: TOOLBOX_VERSION (default from the VERSION file) and a build
# number that always increases (commit count), so updates sort correctly.
VERSION="${TOOLBOX_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cd "$ROOT/App"
swift build -c "$CONFIG" --product Toolbox "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Toolbox" "$APP/Contents/MacOS/Toolbox"
# SwiftPM resource bundles (e.g. SwiftTerm's) live next to the binary.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# Package products built as dynamic libraries (RoyalVNCKit) are loaded via
# @rpath; ship them in Frameworks and point the executable there.
for dylib in "$BIN_DIR"/*.dylib; do
  [[ -e "$dylib" ]] || continue
  cp "$dylib" "$APP/Contents/Frameworks/"
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/$(basename "$dylib")" >/dev/null
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Toolbox" 2>/dev/null || true

# Sparkle (over-the-air updates) is a framework with helper programs inside.
# The app is not sandboxed, so Sparkle's two XPC services are never used
# and are left out of the bundle. What remains is signed from the inside
# out, each piece by itself: that order is what Sparkle's documentation
# gives, and it warns against --deep.
if [[ -d "$BIN_DIR/Sparkle.framework" ]]; then
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  ditto "$BIN_DIR/Sparkle.framework" "$SPARKLE"
  rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
  # Headers and module maps are for building against the framework.
  for part in Headers PrivateHeaders Modules; do
    rm -rf "$SPARKLE/Versions/B/$part" "$SPARKLE/$part"
  done
  codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate" >/dev/null 2>&1
  codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app" >/dev/null 2>&1
  codesign "${SIGN_FLAGS[@]}" "$SPARKLE" >/dev/null 2>&1
  # Sparkle's license asks that its notice travels with every copy.
  if [[ -f "$SPARKLE_BIN/../LICENSE" ]]; then
    mkdir -p "$APP/Contents/Resources/Licenses"
    cp "$SPARKLE_BIN/../LICENSE" "$APP/Contents/Resources/Licenses/Sparkle.txt"
  fi
fi

# With a binary framework in the package, SwiftPM leaves a search path into
# its own build folder in the executable. The bundle has no use for it, and
# in a release it would name the Mac the build was made on.
while read -r rpath; do
  if [[ "$rpath" == "$ROOT"/* ]]; then
    install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/Toolbox" 2>/dev/null
  fi
done < <(otool -l "$APP/Contents/MacOS/Toolbox" | awk '/LC_RPATH/ {getline; getline; print $2}')
cp "$ROOT/App/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Shown when macOS asks whether the app may read a protected folder.
FILES_PURPOSE="Toolbox reads files here when you paste them into a remote desktop, transfer them to a server, or work with them in a local terminal."
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Toolbox</string>
  <key>CFBundleIdentifier</key><string>com.dobbs.Toolbox</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Toolbox</string>
  <key>CFBundleDisplayName</key><string>Toolbox</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>SUFeedURL</key><string>$UPDATE_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$UPDATE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SURequireSignedFeed</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>$FILES_PURPOSE</string>
  <key>NSDocumentsFolderUsageDescription</key><string>$FILES_PURPOSE</string>
  <key>NSDownloadsFolderUsageDescription</key><string>$FILES_PURPOSE</string>
  <key>NSRemovableVolumesUsageDescription</key><string>$FILES_PURPOSE</string>
  <key>NSNetworkVolumesUsageDescription</key><string>$FILES_PURPOSE</string>
</dict>
</plist>
PLIST

APP_SIGN_FLAGS=("${SIGN_FLAGS[@]}")
if [[ "${TOOLBOX_HARDENED:-0}" == "1" && "$SIGN_ID" == "-" ]]; then
  APP_SIGN_FLAGS+=(--entitlements "$ROOT/App/Signing/rehearsal.entitlements")
fi
codesign "${APP_SIGN_FLAGS[@]}" "$APP" >/dev/null
if [[ "$SIGN_ID" == "-" ]]; then
  echo "warning: signed ad hoc; the Keychain will ask about the vault key again after every rebuild." >&2
  echo "         Run 'make signing' once to give the app a stable identity." >&2
else
  echo "signed with: $SIGN_NAME"
fi
echo "ok: $APP"
