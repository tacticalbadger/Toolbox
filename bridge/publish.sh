#!/usr/bin/env bash
# Publishes the release built by `make release` as a GitHub Release on this
# repository: tag v<version>, with the DMG, the zip and SHA256SUMS attached,
# so the app can be downloaded from the repo's Releases page, and the update
# feed (appcast.xml), which is what installed copies read to learn that
# there is a new version: publishing is what sends an update out.
#
#   make publish            # after `make release`
#   REPLACE=1 make publish  # re-upload the files of an existing release
#
# Refuses to publish anything that is not notarized and stapled. The notes
# are the standard install text below plus docs/release-notes/<version>.md
# ("In this version" bullets) when that file exists. Needs the GitHub CLI,
# signed in (`gh auth login`). Keep names, hostnames and account details
# out of release notes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
OUT="$ROOT/build/release"
DMG="$OUT/Toolbox-$VERSION.dmg"
ZIP="$OUT/Toolbox-$VERSION.zip"
SUMS="$OUT/SHA256SUMS"
FEED="$OUT/appcast.xml"
source "$ROOT/bridge/update-config.sh"
# The clone's remote may still name an older address of the repository;
# releases go where installed copies look for them.
export GH_REPO="${GH_REPO:-$UPDATE_REPO}"

command -v gh >/dev/null || fail "the GitHub CLI is not installed (brew install gh)"
gh auth status >/dev/null 2>&1 || fail "not signed in to GitHub; run: gh auth login"
[[ -f "$DMG" && -f "$ZIP" && -f "$SUMS" ]] || fail "no release files for $VERSION in build/release; run make release first"
[[ -f "$FEED" ]] || fail "no update feed (build/release/appcast.xml): make release writes it when the update key is on this Mac.
       A release without it would leave installed copies unable to see this or any later version."

echo "==> Checking the files"
(cd "$OUT" && shasum -a 256 -c SHA256SUMS)
xcrun stapler validate "$DMG" >/dev/null 2>&1 || fail "$(basename "$DMG") is not notarized and stapled; run make release without NOTARIZE=0"
ASSESS="$(spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 || true)"
[[ "$ASSESS" == *"Notarized Developer ID"* ]] || fail "Gatekeeper does not accept the DMG: $ASSESS"
echo "notarized and accepted by Gatekeeper"
# The feed has to announce exactly this archive, at the address it will have.
FEED_URL="$(sed -nE 's/.*<enclosure url="([^"]+)".*/\1/p' "$FEED" | head -1)"
[[ "$FEED_URL" == "https://github.com/$GH_REPO/releases/download/$TAG/$(basename "$ZIP")" ]] \
  || fail "the feed points at $FEED_URL, not at this release's archive; run make release again"
FEED_LENGTH="$(sed -nE 's/.* length="([0-9]+)".*/\1/p' "$FEED" | head -1)"
[[ "$FEED_LENGTH" == "$(stat -f %z "$ZIP")" ]] || fail "the feed was written for another archive (length $FEED_LENGTH); run make release again"
echo "the update feed announces this archive"

# The tag points at the commit the release was built from: it has to be on GitHub.
git fetch -q origin
HEAD_SHA="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$HEAD_SHA" origin/main || fail "the current commit is not on origin/main; push first"
[[ -z "$(git status --porcelain)" ]] || echo "note: the working tree has uncommitted changes; the tag will point at the last commit"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<NOTES_EOF
Toolbox is a native macOS client for SSH, RDP, VNC and file transfer, with split panes, workspace tabs, a credential vault and 1Password and Active Directory integration.

## Install

1. Download **Toolbox-$VERSION.dmg** below.
2. Open it and drag **Toolbox** to **Applications**.
3. Launch it from Applications. It is signed and notarized, so macOS opens it without a security warning.

Requires a Mac with Apple silicon running macOS 14 or newer.

## First run

- Your connections and credentials are stored only on your Mac. Nothing is shared between users.
- The first time you save a credential, macOS asks for Touch ID or your login password to unlock the vault. You can turn that off under **Toolbox ▸ Require Touch ID to Unlock Vault**.
- 1Password integration needs the 1Password CLI: \`brew install 1password-cli\`, then enable **Integrate with 1Password CLI** in 1Password ▸ Settings ▸ Developer.
- From 0.5.0 on, Toolbox updates itself: it looks for a new version once a day and offers it with its release notes. **Toolbox ▸ Check for Updates Automatically** switches that off; **Check for Updates…** looks right away. Keep the app in Applications for this to work.
NOTES_EOF
if [[ -f "docs/release-notes/$VERSION.md" ]]; then
  printf '\n## In this version\n\n' >> "$NOTES"
  cat "docs/release-notes/$VERSION.md" >> "$NOTES"
fi
printf '\n`SHA256SUMS` lists checksums for the downloads. The .zip contains the same app without the disk image.\n' >> "$NOTES"

if gh release view "$TAG" >/dev/null 2>&1; then
  [[ "${REPLACE:-0}" == "1" ]] || fail "release $TAG already exists. Change VERSION and run make release for a new one, or REPLACE=1 make publish to re-upload this one."
  echo "==> Replacing the files of $TAG"
  gh release upload "$TAG" "$DMG" "$ZIP" "$SUMS" "$FEED" --clobber
  gh release edit "$TAG" --title "Toolbox $VERSION" --notes-file "$NOTES" >/dev/null
else
  echo "==> Creating release $TAG"
  gh release create "$TAG" "$DMG" "$ZIP" "$SUMS" "$FEED" --target "$HEAD_SHA" --title "Toolbox $VERSION" --notes-file "$NOTES" >/dev/null
fi
echo "published: $(gh release view "$TAG" --json url -q .url)"
echo "installed copies look for updates at: $UPDATE_FEED_URL"
