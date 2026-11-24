#!/usr/bin/env bash
# Rehearses an over-the-air update from start to finish with nothing real in
# it: a signing key made for the run, two copies of the current build given
# made-up versions (9.9.1 and 9.9.2) and a bundle identifier of their own,
# and a feed served from a local folder (Sparkle does not read file://
# feeds, so a web server on 127.0.0.1 hands it out for the length of the
# run). No release, no GitHub, not the real update key, not the owner's
# preferences.
#
#   tools/e2e/update-rehearsal.sh [work-dir]      default: build/update-rehearsal
#
# It checks four things and exits non-zero unless all hold:
#   1. The old copy finds the new one in the feed, verifies it, and once it
#      has quit, the copy on disk is the new version.
#   2. That copy, now the new version, finds nothing newer in the same feed.
#   3. With the archive altered after it was signed, nothing is installed
#      and the app says why.
#   4. The same with the feed altered after it was signed.
#
# Needs build/Toolbox.app (make app) and python3 for the web server
# (PORT=8497 by default). The copies run in the background.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/Toolbox.app"
WORK="${1:-$ROOT/build/update-rehearsal}"
SPARKLE_BIN="$ROOT/App/.build/artifacts/sparkle/Sparkle/bin"
BUNDLE_ID="com.dobbs.Toolbox.update-rehearsal"
PORT="${PORT:-8497}"
BASE="http://127.0.0.1:$PORT"
OLD_VERSION="9.9.1"; OLD_BUILD="99901"
NEW_VERSION="9.9.2"; NEW_BUILD="99902"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[[ -d "$APP" ]] || fail "no app bundle at build/Toolbox.app; run make app first"
[[ -x "$SPARKLE_BIN/sign_update" ]] \
  || fail "Sparkle's tools are not in the package cache ($SPARKLE_BIN): the app has no updater, or make app has not run since it got one"
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] \
  || fail "build/Toolbox.app has no Sparkle.framework in it: the bundle was made without the updater"

version_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist"; }
has_version() { [[ "$(version_of "$1" 2>/dev/null)" == "$2" ]]; }

# Waits until a command succeeds: wait_for <seconds> <command…>
wait_for() {
  local limit="$1" waited=0
  shift
  until "$@" >/dev/null 2>&1; do
    sleep 0.5
    waited=$((waited + 1))
    [[ "$waited" -lt $((limit * 2)) ]] || return 1
  done
}

running() { pgrep -f "$1/Contents/MacOS/Toolbox" >/dev/null; }
stop() { pkill -f "$1/Contents/MacOS/Toolbox" 2>/dev/null || true; wait_for 20 not_running "$1" || true; }
not_running() { ! running "$1"; }

rm -rf "$WORK"
mkdir -p "$WORK"
chmod 700 "$WORK"

# The feeds are read over HTTP from this folder, on this Mac only.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK" > "$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
wait_for 10 nc -z 127.0.0.1 "$PORT" || fail "the local web server did not start on port $PORT (in use? set PORT)"

# --- a key for this run only ---------------------------------------------------
step "Making a signing key for the rehearsal"
read -r SEED PUBLIC < <(swift - <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)
[[ -n "$SEED" && -n "$PUBLIC" ]] || fail "could not make a key"
printf '%s' "$SEED" > "$WORK/key"
chmod 600 "$WORK/key"
echo "public key: $PUBLIC"

# --- two copies of the build, as two versions -----------------------------------
SIGNING="$(codesign -dvv "$APP" 2>&1 || true)"
if [[ "$SIGNING" == *"Signature=adhoc"* ]]; then
  IDENTITY="-"
else
  IDENTITY="$(sed -n 's/^Authority=//p' <<<"$SIGNING" | head -1)"
fi
[[ -n "$IDENTITY" ]] || fail "build/Toolbox.app is not signed"
SIGN_FLAGS=(--force --sign "$IDENTITY" --timestamp=none)
[[ "$SIGNING" == *"flags="*"runtime"* ]] && SIGN_FLAGS+=(--options runtime)

# make_copy <dir> <version> <build>: a copy of the build that claims to be
# that version, trusts the rehearsal key, keeps its own preferences, and
# may read plain HTTP from this Mac (the real app may not).
make_copy() {
  local dir="$1" plist="$1/Toolbox.app/Contents/Info.plist"
  mkdir -p "$dir"
  ditto "$APP" "$dir/Toolbox.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" -c "Set :CFBundleVersion $3" \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :SUPublicEDKey $PUBLIC" \
    -c "Add :NSAppTransportSecurity dict" \
    -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" \
    -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$plist"
  codesign "${SIGN_FLAGS[@]}" "$dir/Toolbox.app" >/dev/null 2>&1
  codesign --verify --deep --strict "$dir/Toolbox.app" || fail "the copy in $dir does not verify after signing"
}

# make_feed <folder>: the new version's archive in that folder, and a feed
# for it made by the tool the release uses. The copies ask for a signed
# feed (SURequireSignedFeed), so generate_appcast signs it as well as the
# archive.
make_feed() {
  mkdir -p "$1"
  cp "$WORK/Toolbox-$NEW_VERSION.zip" "$1/"
  printf -- '- A rehearsal update. **Nothing** in it is real.\n' > "$1/Toolbox-$NEW_VERSION.md"
  "$SPARKLE_BIN/generate_appcast" --ed-key-file "$WORK/key" --download-url-prefix "$BASE/$(basename "$1")/" \
    --embed-release-notes -o "$1/appcast.xml" "$1" > "$1/generate_appcast.log" 2>&1 \
    || { cat "$1/generate_appcast.log"; fail "generate_appcast could not make the feed in $1"; }
  grep -q "sparkle:edSignature=" "$1/appcast.xml" || fail "the feed in $1 has no signed archive in it"
}

step "Making $NEW_VERSION ($NEW_BUILD), its archive and three feeds"
make_copy "$WORK/new" "$NEW_VERSION" "$NEW_BUILD"
ditto -c -k --sequesterRsrc --keepParent "$WORK/new/Toolbox.app" "$WORK/Toolbox-$NEW_VERSION.zip"
make_feed "$WORK/feed"

# The archive altered after the feed was made: four bytes in its middle,
# same length, same name.
make_feed "$WORK/bad-archive"
BAD="$WORK/bad-archive/Toolbox-$NEW_VERSION.zip"
printf '\x00\x11\x22\x33' | dd of="$BAD" bs=1 seek=$(( $(stat -f %z "$BAD") / 2 )) conv=notrunc 2>/dev/null
cmp -s "$BAD" "$WORK/Toolbox-$NEW_VERSION.zip" && fail "the archive did not change"

# The feed altered after it was signed: the release notes say something else.
make_feed "$WORK/bad-feed"
sed -i '' 's/A rehearsal update\./An update from somewhere else./' "$WORK/bad-feed/appcast.xml"
grep -q "from somewhere else" "$WORK/bad-feed/appcast.xml" || fail "the feed did not change"

# launch <copy-dir> <feed-folder> <log>: the old copy, looking at that feed,
# set to take updates without asking so nothing has to be clicked.
launch() {
  : > "$3"
  open -g -n "$1/Toolbox.app" --stderr "$3" \
    --env TOOLBOX_STORE_PATH="$WORK/store.json" \
    --env TOOLBOX_VAULT_PATH="$WORK/vault.json" \
    --env TOOLBOX_KNOWN_HOSTS="$WORK/known_hosts" \
    --env TOOLBOX_KEYCHAIN_SERVICE=com.dobbs.Toolbox.vault-key.e2e \
    --args --updater-feed "$BASE/$(basename "$2")/appcast.xml" --demo-update \
    -vaultRequiresAuth NO -SUEnableAutomaticChecks YES -SUAutomaticallyUpdate YES
}
said() { grep -Eq "$1" "$2"; }

RESULT=0

# --- 1. the update arrives and is installed ---------------------------------------
step "1. $OLD_VERSION looks at the feed"
make_copy "$WORK/old" "$OLD_VERSION" "$OLD_BUILD"
launch "$WORK/old" "$WORK/feed" "$WORK/old.log"
if wait_for 90 said "updates: $NEW_VERSION is verified and will be installed when the app quits" "$WORK/old.log"; then
  grep 'updates: ' "$WORK/old.log" | sed -E 's/^.*updates: /  app: /'
  stop "$WORK/old/Toolbox.app"
  # The installer replaces the bundle once the app is gone.
  wait_for 90 has_version "$WORK/old/Toolbox.app" "$NEW_VERSION" || true
  NOW="$(version_of "$WORK/old/Toolbox.app" 2>/dev/null || echo missing) ($(build_of "$WORK/old/Toolbox.app" 2>/dev/null || echo -))"
  if [[ "$NOW" == "$NEW_VERSION ($NEW_BUILD)" ]] && codesign --verify --deep --strict "$WORK/old/Toolbox.app" 2>/dev/null; then
    echo "PASS: the copy on disk is now $NOW and its signature verifies"
  else
    echo "FAIL: after quitting, the copy on disk is $NOW, not $NEW_VERSION ($NEW_BUILD)"
    RESULT=1
  fi
else
  stop "$WORK/old/Toolbox.app"
  echo "FAIL: the old copy never said it had an update ready. What it logged:"
  grep -E 'updates: |--updater-feed|--demo-update' "$WORK/old.log" | sed -E 's/^.*Toolbox\[[0-9:]+\] /  app: /' | tail -8
  [[ -s "$WORK/old.log" ]] || echo "  (nothing)"
  RESULT=1
fi

# --- 2. the updated copy is content --------------------------------------------------
step "2. The updated copy looks at the same feed"
if has_version "$WORK/old/Toolbox.app" "$NEW_VERSION"; then
  launch "$WORK/old" "$WORK/feed" "$WORK/updated.log"
  wait_for 60 said "updates: (nothing newer|stopped|found)" "$WORK/updated.log" || true
  sleep 1
  grep 'updates: ' "$WORK/updated.log" | sed -E 's/^.*updates: /  app: /' || true
  stop "$WORK/old/Toolbox.app"
  if said "updates: nothing newer in the feed" "$WORK/updated.log" && ! said "updates: found" "$WORK/updated.log"; then
    echo "PASS: nothing is offered to a copy that is already $NEW_VERSION"
  else
    echo "FAIL: the updated copy did not report that nothing newer is in the feed"
    RESULT=1
  fi
else
  echo "FAIL: there is no updated copy to try (check 1 did not pass)"
  RESULT=1
fi

# refused <name> <feed-folder> <what was done> <reason> [<must not appear>]:
# the old version must stay what it is and give that reason, which is what
# tells a refusal for the right cause from one that merely failed.
refused() {
  make_copy "$WORK/$1" "$OLD_VERSION" "$OLD_BUILD"
  launch "$WORK/$1" "$2" "$WORK/$1.log"
  wait_for 90 said "updates: (stopped|done|.*when the app quits)" "$WORK/$1.log" || echo "  (the app reported nothing within 90 s)"
  sleep 2
  grep 'updates: ' "$WORK/$1.log" | sed -E 's/^.*updates: /  app: /' || true
  stop "$WORK/$1/Toolbox.app"
  sleep 15   # as long as an installer would have needed
  local now
  now="$(version_of "$WORK/$1/Toolbox.app" 2>/dev/null || echo missing)"
  if [[ "$now" == "$OLD_VERSION" ]] && said "updates: stopped: $4" "$WORK/$1.log" \
     && ! said "when the app quits" "$WORK/$1.log" && ! { [[ -n "${5:-}" ]] && said "$5" "$WORK/$1.log"; }; then
    echo "PASS: nothing was installed (still $now), refused as improperly signed"
  else
    echo "FAIL: with $3 the copy is $now; expected $OLD_VERSION, no install, and the reason \"$4\" in the log"
    RESULT=1
  fi
}

# --- 3. an archive that was altered after signing is refused -----------------------
# The feed is intact, so the update is found and downloaded; the archive's
# signature is what stops it.
step "3. $OLD_VERSION looks at a feed whose archive was altered after signing"
refused old-bad-archive "$WORK/bad-archive" "the altered archive" "The update is improperly signed"
said "updates: found $NEW_VERSION" "$WORK/old-bad-archive.log" || { echo "FAIL: the update was not even found, so the archive was never judged"; RESULT=1; }

# --- 4. a feed that was altered after signing is refused ---------------------------
# Nothing in such a feed is believed: no update is "found" and nothing is
# downloaded.
step "4. $OLD_VERSION looks at a feed that was altered after signing"
refused old-bad-feed "$WORK/bad-feed" "the altered feed" "The update feed is improperly signed" "updates: (found|downloaded)"
if grep -q "GET /bad-feed/Toolbox-" "$WORK/server.log"; then
  echo "FAIL: the archive was downloaded on the word of an altered feed"
  RESULT=1
fi

echo
[[ "$RESULT" == 0 ]] && echo "update rehearsal: all four checks passed" || echo "update rehearsal: FAILED"
exit "$RESULT"
