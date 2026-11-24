# Over-the-air updates: where the app looks for them and the key they are
# checked against. Sourced by bundle-app.sh (the app's Info.plist),
# release.sh (the feed) and publish.sh. Expects ROOT to be set.
#
# The feed is a small file attached to every GitHub Release;
# "releases/latest/download" always serves the newest release's copy, so
# there is no server to run. Every build that has shipped carries this
# address: if the repository is renamed or moved, GitHub's redirect is all
# that keeps those installs updating, so ship a build with the new address
# before relying on anything else.
UPDATE_REPO="tacticalbadger/Toolbox"
UPDATE_FEED_URL="https://github.com/$UPDATE_REPO/releases/latest/download/appcast.xml"

# The public half of the update key (EdDSA). The app accepts an update, and
# the feed that announces it, only if they are signed with the private
# half. That half lives in the login keychain of the Mac that makes
# releases, under the account name below, and never in the repository.
# Sparkle's own tools manage it:
#   $SPARKLE_BIN/generate_keys --account toolbox-update-key          show the public key (creates a key if none)
#   $SPARKLE_BIN/generate_keys --account toolbox-update-key -x FILE  write the private key to FILE (to move or back up)
#   $SPARKLE_BIN/generate_keys --account toolbox-update-key -f FILE  take the private key from FILE (on the other Mac)
# Lose the private key and no install can be updated over the air again:
# everyone has to download a build by hand once more.
UPDATE_KEY_ACCOUNT="toolbox-update-key"
UPDATE_PUBLIC_KEY="h2Ue9u/hwW6kZp5iTEZ6aZBh5jzWhsn/CZe+laVMknw="

# Sparkle's command-line tools, unpacked by SwiftPM with the framework.
SPARKLE_BIN="$ROOT/App/.build/artifacts/sparkle/Sparkle/bin"
