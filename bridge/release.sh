#!/usr/bin/env bash
# Builds a Toolbox release for colleagues: release build, signed with your
# Developer ID Application certificate and the hardened runtime, notarized
# by Apple, stapled, and packed into build/Toolbox-<version>.dmg (plus a
# .zip). Recipients open it like any downloaded app, with no Gatekeeper
# warning.
#
# One-time setup per Mac (see README, "Sharing builds with the team"):
#   1. A "Developer ID Application: <Name> (<TEAMID>)" certificate with its
#      private key in the login keychain.
#   2. Notarization credentials stored under a keychain profile:
#        xcrun notarytool store-credentials toolbox-notary \
#          --apple-id <you@example.com> --team-id <TEAMID>
#      (it asks for an app-specific password from account.apple.com).
#   3. The update key in the login keychain (see bridge/update-config.sh):
#      installed copies take an update only if it is signed with it. The
#      first time, macOS asks whether generate_appcast may use the key:
#      choose Always Allow.
#
#   make release                      # everything
#   NOTARIZE=0 make release           # sign and package only
#   NOTARY_PROFILE=other make release # different keychain profile
#   TOOLBOX_SIGN_IDENTITY=<sha1|name> # pick among several Developer IDs
#   ALLOW_ADHOC=1 NOTARIZE=0          # rehearse the pipeline without a certificate
#   ALLOW_BUILD_PATHS=1               # keep going if the binary names this Mac (never for a published build)
#   TOOLBOX_UPDATE_KEY_FILE=<file>    # take the update key from a file instead of the keychain
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Toolbox.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-toolbox-notary}"
NOTARIZE="${NOTARIZE:-1}"
unset DEVELOPER_DIR
source "$ROOT/bridge/update-config.sh"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- identity ---------------------------------------------------------------
if [[ -z "${TOOLBOX_SIGN_IDENTITY:-}" ]]; then
  line="$(security find-identity -v -p codesigning | grep -F "Developer ID Application:" | head -1 || true)"
  if [[ -n "$line" ]]; then
    TOOLBOX_SIGN_IDENTITY="$(awk '{print $2}' <<<"$line")"
    IDENTITY_NAME="$(sed -E 's/^[^"]*"(.*)"[^"]*$/\1/' <<<"$line")"
  elif [[ "${ALLOW_ADHOC:-0}" == "1" ]]; then
    TOOLBOX_SIGN_IDENTITY="-"
    IDENTITY_NAME="ad-hoc (rehearsal only, not shareable)"
    NOTARIZE=0
  else
    fail "no \"Developer ID Application\" certificate in the keychain.
       Create one in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application,
       or import the .p12 from the Mac that has it. Then run make release again."
  fi
else
  IDENTITY_NAME="$TOOLBOX_SIGN_IDENTITY"
fi
export TOOLBOX_SIGN_IDENTITY TOOLBOX_HARDENED=1
echo "signing identity: $IDENTITY_NAME"

if [[ "$NOTARIZE" == "1" ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarization profile \"$NOTARY_PROFILE\" is missing or invalid. Create it with:
       xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <you@example.com> --team-id <TEAMID>"
fi

# --- build ------------------------------------------------------------------
step "Building the core (release)"
"$ROOT/bridge/build-core.sh" | grep -E "^ok:" || true
step "Building and signing the app (release, hardened runtime)"
CONFIG=release TOOLBOX_SIGN_IDENTITY="$TOOLBOX_SIGN_IDENTITY" "$ROOT/bridge/bundle-app.sh" | grep -vE "^\[|Compiling|search path" || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
NAME="Toolbox-$VERSION"
OUT="$ROOT/build/release"
rm -rf "$OUT"; mkdir -p "$OUT"

# The download is public. Nothing in it may name the Mac it was built on:
# both build scripts rewrite source paths for release builds, and this
# makes sure nothing slipped through (a new dependency, a new tool).
step "Checking for paths from this Mac"
LEAKS=0
while IFS= read -r -d '' item; do
  # Capture first, as below: `grep -q` in a pipeline trips pipefail.
  found="$(strings -a "$item" | grep -c -F -e "$HOME" -e "/Users/$(id -un)" || true)"
  if [[ "$found" != "0" ]]; then
    echo "  ${item#"$APP"/}: $found strings contain a path under $HOME"
    LEAKS=1
  fi
done < <(find "$APP/Contents/MacOS" "$APP/Contents/Frameworks" -type f -print0)
if [[ "$LEAKS" == "1" && "${ALLOW_BUILD_PATHS:-0}" != "1" ]]; then
  fail "the app embeds paths from this Mac (see above); fix the path remapping in bridge/build-core.sh and
       bridge/bundle-app.sh, or set ALLOW_BUILD_PATHS=1 for a build that will not be published"
fi
[[ "$LEAKS" == "1" ]] || echo "none"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
grep -E "^(Authority|TeamIdentifier|CodeDirectory)" <<<"$SIGNATURE" || true
[[ "$SIGNATURE" == *"runtime"* ]] || fail "the app is not signed with the hardened runtime"
if [[ "$TOOLBOX_SIGN_IDENTITY" != "-" ]]; then
  # Apple refuses to notarize signatures without a secure timestamp; catch
  # that here instead of after a round trip to the notary service.
  while IFS= read -r -d '' item; do
    # Only code carries a signature of its own; a framework also holds
    # property lists, strings and pictures.
    kind="$(file -b "$item")"
    [[ "$kind" == *"Mach-O"* ]] || continue
    # Capture first: piping into `grep -q` trips pipefail when grep exits early.
    details="$(codesign -dvv "$item" 2>&1 || true)"
    [[ "$details" == *$'\n'"Timestamp="* ]] \
      || fail "no secure timestamp in the signature of ${item#"$APP"/}"
    [[ "$details" == *"flags="*"runtime"* ]] \
      || fail "${item#"$APP"/} is not signed with the hardened runtime"
  done < <(find "$APP/Contents/MacOS" "$APP/Contents/Frameworks" -type f -print0)
  echo "secure timestamps and hardened runtime on every executable: present"
fi

notarize() { # $1 = file to submit
  step "Notarizing $(basename "$1") (usually a few minutes)"
  local result id status
  result="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)"
  id="$(/usr/libexec/PlistBuddy -c 'Print :id' /dev/stdin <<<"$result" 2>/dev/null || true)"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' /dev/stdin <<<"$result" 2>/dev/null || true)"
  echo "submission $id: $status"
  if [[ "$status" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$OUT/notary-$id.json" >/dev/null 2>&1 \
      && echo "Apple's log: $OUT/notary-$id.json"
    fail "notarization was not accepted"
  fi
}

# --- notarize the app, staple it --------------------------------------------
if [[ "$NOTARIZE" == "1" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/submit.zip"
  notarize "$OUT/submit.zip"
  rm -f "$OUT/submit.zip"
  step "Stapling the ticket to the app"
  xcrun stapler staple "$APP"
fi

# --- package ----------------------------------------------------------------
step "Packaging"
# The zip is also what installed copies download as an update; Sparkle asks
# for these options so nothing about the bundle changes in the archive.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Toolbox $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/$NAME.dmg"
if [[ "$TOOLBOX_SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$TOOLBOX_SIGN_IDENTITY" "$OUT/$NAME.dmg"
fi
if [[ "$NOTARIZE" == "1" ]]; then
  notarize "$OUT/$NAME.dmg"
  step "Stapling the ticket to the disk image"
  xcrun stapler staple "$OUT/$NAME.dmg"
  step "Gatekeeper assessment"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT/$NAME.dmg"
fi

# --- the update feed ---------------------------------------------------------
# Installed copies read build/release/appcast.xml from the newest GitHub
# Release (make publish uploads it) and download the zip it names. Both are
# signed here with the update key; the app refuses either without it.
step "Signing the update and writing the feed"
HAVE_KEY="$("$SPARKLE_BIN/generate_keys" --account "$UPDATE_KEY_ACCOUNT" -p 2>/dev/null || true)"
KEY_ARGS=(--account "$UPDATE_KEY_ACCOUNT")
if [[ -n "${TOOLBOX_UPDATE_KEY_FILE:-}" ]]; then
  KEY_ARGS=(--ed-key-file "$TOOLBOX_UPDATE_KEY_FILE")
elif [[ "$HAVE_KEY" != "$UPDATE_PUBLIC_KEY" ]]; then
  if [[ "$NOTARIZE" == "1" ]]; then
    fail "the update key is not in this Mac's keychain (account $UPDATE_KEY_ACCOUNT), or is a different key.
       Without it nobody's copy can be updated. Bring it over from the Mac that has it:
         $SPARKLE_BIN/generate_keys --account $UPDATE_KEY_ACCOUNT -x <file>     there
         $SPARKLE_BIN/generate_keys --account $UPDATE_KEY_ACCOUNT -f <file>     here
       or set TOOLBOX_UPDATE_KEY_FILE to a file that holds it."
  fi
  KEY_ARGS=()
  echo "no update key on this Mac: no feed (this build cannot be published)"
fi
if [[ "${#KEY_ARGS[@]}" -gt 0 ]]; then
  FEED_STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE" "$FEED_STAGE"' EXIT
  cp "$OUT/$NAME.zip" "$FEED_STAGE/"
  # Release notes with the archive's name are shown in the update window.
  [[ -f "$ROOT/docs/release-notes/$VERSION.md" ]] && cp "$ROOT/docs/release-notes/$VERSION.md" "$FEED_STAGE/$NAME.md"
  "$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" \
    --download-url-prefix "https://github.com/$UPDATE_REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$UPDATE_REPO/releases" \
    --embed-release-notes --maximum-versions 1 -o "$OUT/appcast.xml" "$FEED_STAGE" \
    || fail "generate_appcast could not write the feed"
  # What every installed copy will do with it: check the archive's
  # signature against the public key in the app. A release signed with any
  # other key would be refused by all of them.
  FEED_SIGNATURE="$(sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p' "$OUT/appcast.xml" | head -1)"
  APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
  [[ -n "$FEED_SIGNATURE" ]] || fail "the feed names no signed archive"
  VERDICT="$(swift - "$APP_KEY" "$FEED_SIGNATURE" "$OUT/$NAME.zip" <<'SWIFT' 2>/dev/null || true
import CryptoKit
import Foundation
let arguments = CommandLine.arguments
guard arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let archive = FileManager.default.contents(atPath: arguments[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    print("unreadable")
    exit(1)
}
print(key.isValidSignature(signature, for: archive) ? "valid" : "INVALID")
SWIFT
)"
  [[ "$VERDICT" == "valid" ]] \
    || fail "the archive's signature does not verify against the key in the app ($VERDICT): installed copies would refuse this update"
  grep -q "v$VERSION/$NAME.zip" "$OUT/appcast.xml" || fail "the feed does not point at this release's archive"
  echo "archive signature verifies against the key in the app; feed written"
fi

shasum -a 256 "$OUT/$NAME.dmg" "$OUT/$NAME.zip" | sed "s|$OUT/||" > "$OUT/SHA256SUMS"
step "Done: Toolbox $VERSION (build $BUILD)"
ls -lh "$OUT" | awk 'NR>1 {print "  " $5 "  " $9}'
[[ "$NOTARIZE" == "1" ]] || echo "  (not notarized: recipients would see a Gatekeeper warning)"
