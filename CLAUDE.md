# Toolbox — working notes for Claude

Read this first on any Mac. It is the handoff between the two machines this
app is developed on; memory files do not travel, this file does.
**Update the "Current state" section at the end in every commit** (write it
before committing, so the commit describes itself).

## What this is

Toolbox is a macOS native replacement for Termius + Royal TSX for the owner
(uses Termius, Royal TSX and 1Password daily; prefers Rust).
SSH terminals and local shells, RDP and VNC with dynamic resolution, file
transfer; every session in a workspace tab of its own, with split panes for
putting sessions side by side; connection objects in a Royal-style folder tree, a
credential vault with Touch ID, SSH key identities, dynamic folders fed
by 1Password (`op` CLI) and Active Directory, and updates over the air
(Sparkle). Royal TS reference material
the owner provided is in `docs/royalts-reference/`. The owner's Royal layout to
mirror: document "Work" → folder "ACME" → dynamic folders "1Password" and the
AD provider (OU hierarchy), folder "Jump Boxes".

Repo: https://github.com/tacticalbadger/Toolbox.git (public). **One branch: `main`.**
The owner asked for a single branch on 2026-11-14; commit and push to `main`
directly and do not create feature branches unless they ask. The old
`toolbox-phases-1-3` branch was merged and deleted.

## Starting a session on either Mac

1. `git status` and `git pull` on `main`. If the working tree only shows
   `App/`, `core/` or `build/` as untracked and the source is missing, a GUI
   client (GitKraken did this once) switched to a stale branch: run
   `git checkout main && git pull` and never stage those folders. They hold
   build caches (`core/target` alone is ~14 GB) and `build/e2e` holds test
   private keys.
2. `make core && make app` (core first: bindings and the static library are
   generated, not in git). Then `make test`.
3. Read **Current state** at the end of this file, then carry on.
4. Before ending: update Current state, commit to `main`, push.

## Layout

- `core/toolbox-core/` — Rust core (edition 2021) exposed through UniFFI
  0.32: `ssh.rs` (russh), `sftp.rs` (russh-sftp), `rdp.rs` (IronRDP,
  git-pinned: session loop, one thread per session), `rdp_surface.rs` (the
  IOSurface a session paints into), `rdp_h264.rs` (H.264 through
  VideoToolbox for the graphics pipeline), `rdp_clipboard.rs` (CLIPRDR
  backend, file lists, file ranges), `vault.rs` (XChaCha20-Poly1305),
  `onepassword.rs` (`op` subprocess), `ad.rs` (ldap3), `ftp.rs` (FTP /
  explicit FTPS via suppaftp), `store.rs` (connections/credentials/
  providers/folders JSON document), `error.rs`. Test servers behind the
  `test-support` feature: `ssh_test_server.rs`, `rdp_test_server.rs`
  (optional graphics pipeline, scriptable clipboard), `ftp_test_server.rs`
  (libunftp); examples `echo_server` (SSH+SFTP :2222), `rdp_server` (:3390;
  `--graphics-pipeline`, `--paste`, `--copy-text`) and `ftp_server`
  (`--port`, `--tls`), all demo/secret. `tests/data/quadrants.h264` is the
  H.264 test stream; `tools/make-h264-fixture.swift` regenerates it.
- `App/` — SwiftPM package. AppKit shell: `App/` (delegate, menu,
  `Updates.swift`: the Sparkle updater),
  `Workspace/` (window = workspace tab, `PaneContainerViewController`,
  `PaneView`, `PaneLayout`), `Terminal/` (SwiftTerm: `TerminalSessionView`
  for SSH, `LocalTerminalView` for a shell on this Mac), `Remote/` (RDP via
  IOSurface layer plus clipboard sharing, VNC via RoyalVNCKit), `Files/`
  (SFTP browser, SwiftUI), `Sidebar/` (NSOutlineView tree, SwiftUI editors,
  `CredentialPicker.swift` with the search popover), `Model/` (AppModel,
  VaultManager, CredentialResolver, ProviderSync), `Support/`
  (`Snapshot.swift`: the `--snapshot` aid; `FilterPasteCheck.swift`: the
  `--demo-filter-paste` aid; `ShortcutPress.swift`: a ⌘ shortcut sent the
  way the keyboard sends it). `Sources/Generated/` and
  `Vendor/` are produced by `make core` and gitignored.
- `bridge/` — build scripts: `build-core.sh`, `bundle-app.sh`,
  `signing-identity.sh`, `release.sh` (`make release`), `publish.sh`
  (`make publish`: GitHub Release with the notarized DMG and the update
  feed), `update-config.sh` (where updates come from and the public half
  of the key they are checked against; the other scripts source it),
  `make-icon.swift`.
  `VERSION` holds the marketing version; the build number is the commit
  count.
- `tools/e2e/` — end-to-end harness (fixture, test servers, launch,
  capture, `update-rehearsal.sh`: a whole over-the-air update with nothing
  real in it). `docs/SECURITY-REVIEW.md` — review findings and addenda.

## First time on a Mac

The full dependency table is in README.md ("Dependencies"). In short:

1. Apple silicon Mac, macOS 14+. Xcode at `/Applications/Xcode.app`
   (built with 27.2; the SwiftUI macro plugin is borrowed from it, the
   license need not be accepted for `make app`) and the Command Line Tools
   (`xcode-select -p` should print `/Library/Developer/CommandLineTools`;
   the scripts unset `DEVELOPER_DIR`).
2. Rust via rustup, stable (built with 1.100). Network on first build:
   crates.io, IronRDP from GitHub, SwiftTerm, RoyalVNCKit and Sparkle (a
   prebuilt framework, with its command-line tools in
   `App/.build/artifacts/sparkle/Sparkle/bin`) via SwiftPM.
3. Optional: `brew install 1password-cli` (providers), `brew install
   xcodegen` (`make xcode`, needs `sudo xcodebuild -license accept`),
   `cargo install cargo-audit`, `brew install gh`.
4. `make core` then `make app` → `build/Toolbox.app`. `make test` → Rust
   tests (72 as of 2026-11-24). `make run` launches the bundle.
5. `make signing` once (asks for the login password): creates and trusts a
   self-signed "Toolbox Local Signing" certificate so the app's signature
   stays stable across builds and the Keychain's "Always Allow" for the
   vault key sticks. Without it `make app` signs ad hoc and warns; the
   Keychain then asks after every rebuild. A Developer ID identity, if one
   is in the keychain, is picked up automatically (`TOOLBOX_SIGN_IDENTITY`
   overrides).
6. `DEVELOPER_DIR` must be unset for cargo/swift builds; the scripts do it.

App data: `~/Library/Application Support/Toolbox/{connections.json,
vault.json}`; Keychain generic password service `com.dobbs.Toolbox.vault-key`
("Toolbox vault key"); UserDefaults domain `com.dobbs.Toolbox`
(`vaultRequiresAuth`, `vaultKeyOwnerCertificate`, sidebar expansion, and
the View ▸ Remote Desktop switches `rdpRetinaResolution`, `rdpFastGraphics`,
`rdpShareClipboard`, all on by default).
The owner's real setup: `op` at `/opt/homebrew/bin/op`, account `work`, vault
`work`; AD binds with their regular domain account.

## Everyday commands

```sh
make core          # Rust → bindings + static lib (run after ANY Rust API change)
make app           # SwiftPM build + bundle (relaunch the app afterwards and say so)
make test          # cargo test --features test-support
make icon          # re-render the icon
cd core && cargo clippy --features test-support && cargo audit
```

Relaunch the app after every `make app` and tell the owner which build is
running; they once tested a stale instance and reported a missing feature.

## End-to-end checks (no real hosts needed)

```sh
tools/e2e/make-fixture.sh            # keys, known_hosts, fake op, store → build/e2e
tools/e2e/servers.sh start           # SSH+SFTP :2222, RDP :3390, FTP :2121, FTPS :2122 (add --exit-after 6 for auto-close)
tools/e2e/launch.sh --connect echo --connect echo-1p   # relaunch against the fixture, Touch ID skipped
tools/e2e/capture.sh                 # screenshot every Toolbox window into build/e2e/shots, report dialogs
tools/e2e/servers.sh stop
```

The RDP test server starts with `--graphics-pipeline --paste`: a client
that takes the pipeline gets an H.264 picture (four coloured quadrants,
top-left), and whatever the app announces on its clipboard is asked for,
with sizes (never contents) logged to `build/e2e/rdp_server.log`.
`RDP_SERVER_ARGS="--copy-text hello" tools/e2e/servers.sh start` gives a
server without the pipeline (so RemoteFX) that copies text on its side.

`launch.sh` quits any running Toolbox first. If the owner has the app open
with real sessions, do not use it: start a second instance with `open -n`
and the same `--env`/`--args`, and stop it by its own PID
(`pgrep -f "$PWD/build/Toolbox.app/Contents/MacOS/Toolbox"`; the owner's
runs from `/Applications`). For a before-and-after against the installed
release, copy `/Applications/Toolbox.app` to a scratch folder and start
the copy the same way, so its process is told apart by path too. Never
point any build at the owner's real store for a check: providers with
auto-refresh sync at launch (real `op`, real LDAP) and that writes the
store. Open a copy from a throwaway Rust example instead and print counts.
`open … --stderr <file>` is how to read such an instance's `NSLog` lines
(`log show` does not return them).

Every instance, whatever store it opens, shares the app's preferences
(`com.dobbs.Toolbox`). The sidebar's record of open folders is the one
thing in there that depends on the store, so an instance started with
`TOOLBOX_STORE_PATH` keeps it under another name (`NSOutlineView Items
sidebar.tree.other-store`; the real one ends in `sidebar.tree`). To check
what a relaunch reopens, write that list by hand, for example
`defaults write com.dobbs.Toolbox "NSOutlineView Items sidebar.tree.other-store" -array group:library folder:ACME prov:ad-fake`,
and delete the key when done. Never print the real list: it holds the
owner's folder names.

`capture.sh` cannot work without Screen Recording permission or with the
screen locked (`ioreg -n Root -d1 | grep IOConsoleLocked`). Use the app's
own `--snapshot <dir>` then: it saves `window-N.png` for every visible
window (sheets and popovers included), `desktop-N.png` for every RDP pane
straight from its surface, and `snapshot.txt` with each pane's state.
With the screen locked the app is never active, so nothing is announced on
the clipboard; `--assume-keyboard` lifts that for a clipboard check. Such
a check uses the real pasteboard: save it and put it back.

Fixture ids: `echo` (key file, folder Jump Boxes), `echo-1p` (1Password
credential through the fake `op`), `echo-folder` (folder credential →
prompts as `folderuser`), `rdp-local`, `vnc-local`, File Transfer
connections `sftp-local`, `ftp-local`, `ftps-local` (self-signed, so it
prompts), plus AD-style generated connections under `ACME/CORP-AD/…`. The
`ad-fake` provider binds with a provider-owned account (`ad-fake#bind`),
uses an existing credential for domain controllers and none for others. The fixture uses its own Keychain item
(`TOOLBOX_KEYCHAIN_SERVICE`); delete it afterwards with
`security delete-generic-password -s com.dobbs.Toolbox.vault-key.e2e`.

Launch args: `--connect <id>` / `--files <id>` / `--local-terminal`
(repeatable; the first session takes the empty workspace, every further
one a tab of its own), `--demo-type <text>` with `--demo-type-after <secs>`
(default 2; types a line into the first local terminal, and only in a run
whose store is named in the environment), `--demo-merge` (after 3 s every
other tab's sessions move into the first workspace as panes),
`--demo-select-tab <n>` (shows that tab after 3 s and the last one again
after 6 s), `--demo-key <letter>` (repeatable: presses ⌘ and that letter
with the keyboard wherever it is, the first after 3 s, each further one
2 s later; a capital adds ⇧, so `T` is New Local Terminal and `f` Find),
`--demo-filter-paste <id>` (see below), `--expand-all`,
`--demo-move` (focused pane → new workspace), `--demo-close` (close the
focused pane after 3 s), `--demo-split` (split it after 3 s, which resizes
an RDP desktop), `--edit-connection <id|new>`,
`--edit-provider <id|new>`, `--set-folder-credential <path>`,
`--demo-provider-account <provider-id>` (saves a typed-in bind account,
then switches to an existing credential, logging each step),
`--demo-provider-rename <provider-id> <name>` (after 3 s, through the
editor's draft and `saveProvider`; logs where the folder went or why it
was refused; a fresh fixture has no password in the vault for `ad-fake`'s
bind account, so that save is refused unless `--demo-provider-account
ad-fake` runs alongside, and `op-fake` has no such account),
`--demo-folder-rename <path> <new path>` (after 3 s),
`--snapshot <dir>` with `--snapshot-after <secs>` (default 6),
`--assume-keyboard`, `--unlock-vault`; defaults overrides
`-vaultRequiresAuth NO`, `-demoCredentialSearch <text>` (credential pickers
open with that search typed), `-rdpFastGraphics NO`,
`-rdpRetinaResolution NO`, `-rdpShareClipboard NO`. Env: `TOOLBOX_STORE_PATH`, `TOOLBOX_VAULT_PATH`,
`TOOLBOX_KNOWN_HOSTS`, `TOOLBOX_KEYCHAIN_SERVICE`.

`--demo-filter-paste <id>` is the check for keyboard shortcuts and for
what a new tab inherits. It presses ⌘V through `NSApp.sendEvent` with the
keyboard in the sidebar's filter (before that connection is opened, and
again with it open), then with the keyboard in the session's pane, then
opens a local terminal and compares the new tab's sidebar with the first
(filter, open folders, selection, scroll position, width). One log line
per step, `filter-paste: …`. The paste steps need the app frontmost (they
log `active=` and `key=`); the clipboard is saved and put back inside the
same call. For `rdp-local` the server's `keys=` count in
`build/e2e/rdp_server.log` goes up by exactly one per run, in the step
where the pane has the keyboard.

The `snapshot.txt` report starts with one line per workspace tab (title,
panes, sessions, whether it is the selected tab and on screen, its
sidebar's filter) and, for a local terminal, what it says about itself and
the last lines of its screen. Terminal panes draw with Metal, so they are
black in `--snapshot` pictures; they are also black in a real screenshot
of a window that is not on screen, because nothing is drawn then. To see a
terminal, the instance has to be in front (`open` without `-g`) and the
screenshot a real one (`screencapture -l <window id>`, ids from
`tools/e2e/winpid.swift`). For everything else start the instance with
`open -g -n …`: it stays behind whatever the owner is working in. The app
used to come to the front at every run, in the middle of their typing.

Coming to the front is not guaranteed: macOS hands the keyboard to a
newly started app only when the app that started it is in front, so a run
launched from the editor's terminal stays behind as soon as the owner
works in something else. `--demo-filter-paste` says so (`active=false
key=false`), and its paste steps then mean nothing and are repeated later.
`--demo-key` falls back to the main window and says so: the menu still
finds its item and the action still travels that window's responder chain
(enough for ⌘⇧T or ⌘F), but the window's views are not offered the key
first. A made-up key event has to report ⇧ the way the keyboard does:
`charactersIgnoringModifiers` keeps the capital, and the menu tells ⌘⇧T
from ⌘T by it (`ShortcutPress`).

Two `--connect rdp-local` in one run: the test server serves one session
at a time, the earlier one ends cleanly when the next connects, and its
tab closes. That is the server, not the app. The SSH server takes any
number at once (since 2026-11-24, see the invariants), and the
`snapshot.txt` line of a file pane says whether it connected and what its
status line reads.

Never rebuild (`make app` replaces the bundle) or edit a shell script
while a run that uses it is going on.

`tools/e2e/update-rehearsal.sh` is the check for over-the-air updates. It
makes a key for the run, two copies of `build/Toolbox.app` that claim to be
9.9.1 and 9.9.2 (own bundle identifier, so own preferences; they trust the
run's key and may read plain HTTP from 127.0.0.1), a feed written by
`generate_appcast` as in a release, and a web server on 127.0.0.1:8497 for
as long as it runs. It passes only if the old copy becomes the new one on
disk after it quits, the updated copy is then offered nothing, an
archive and a feed altered after signing are each refused for that reason
("improperly signed"; for the feed, with no download), and the same feed,
21 days on by a date moved back in the copies' preferences, is read the
way Sparkle's 20-day rule has it and still gets nothing downloaded.
Everything stays in the background and nothing real is touched: not the
update key, not GitHub, not the owner's preferences. A run that passes
removes its folder (`KEEP=1` keeps it; a failed run's stays for a look),
and every run removes what its copies kept in `~/Library` under their own
identifier. The app's part: `--updater-feed <url>`
(honoured only in a run against a store named in the environment; such a
run looks for updates nowhere otherwise), `--demo-update` (look two
seconds after launch, the way the daily check does) and
`--demo-update-window` (what Check for Updates… does; with `--snapshot` it
gives a picture of the update window). The app logs one `updates:` line
per step.

Screenshots need Screen Recording permission for the terminal; GUI
scripting (clicks) is not available without Accessibility permission, so
UI paths are exercised with launch aids or synthetic `NSEvent`s posted from
inside the app. Crash reports land in `~/Library/Logs/DiagnosticReports/`
as `Toolbox-*.ips` (JSON: header line, then body with `threads[].frames`).

## Conventions

- Commit only when the owner asks, on `main`. Commit messages end with the
  co-author line the session's Claude Code harness specifies (on
  2026-11-24: `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`);
  PR bodies with
  `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
- Before committing: scan the diff for keys/tokens, make sure no temporary
  probe code is left, run `make test`, and update **Current state** below.
  The owner's own configuration never goes in git: no real hostnames, domain
  names, usernames, account emails, Team IDs or anything from
  `~/Library/Application Support/Toolbox/`. Use `corp.example`, `CORP\jdoe`
  and placeholders in docs, tests and fixtures. The same goes for anything
  else personal: no names, no employer, and no personal email address in
  commit metadata. Write "the owner" in these notes.
  Never commit `build/`, `core/target/`, `App/.build/`, generated bindings
  or `App/Vendor/` (all gitignored); binaries are not shared through git.
- **The license is proprietary** (the owner, 2026-11-23, for every public
  repository on the account: "the most restricting license my code can
  have"). `LICENSE` is all rights reserved, with one permission: to run
  the builds the owner hands out. Its copyright line carries the account
  name `tacticalbadger`, which the owner chose over a real name so that
  the rule above holds. Do not add an open-source license or a `license`
  field to a manifest, and keep the README's License section in step with
  `LICENSE`. Third-party components keep their own licenses.
- Keep `README.md` "What works" and `docs/SECURITY-REVIEW.md` (an addendum
  per security-relevant change) current.
- Secrets never go in `connections.json`; they live in the vault,
  1Password, or are prompted for. New store fields need `#[serde(default)]`.
- Write shell scripts in bash (`#!/usr/bin/env bash`); zsh word-splitting
  bit earlier scripts.

## Invariants and gotchas (each cost real debugging time)

- `PaneSplitView` must not be its own `NSSplitViewDelegate` (AppKit's
  sidebar category recurses in `respondsToSelector:`); a separate
  `ResizeObserver` is the delegate.
- AppKit offers a key equivalent to every view in the key window, first
  responder or not, before the menu sees it. A view that overrides
  `performKeyEquivalent` must check `window?.firstResponder === self`
  before taking anything. `RdpSessionView` did not until 2026-11-24: with
  a live desktop in the window, ⌘V/⌘C/⌘X/⌘A/⌘Z never reached the
  sidebar's filter and the host got the letter instead (the owner's "I can
  only paste into the filter once"). SwiftTerm and RoyalVNCKit check.
- Where a session goes is decided in one place,
  `WorkspaceWindowController.placeForNewSession()`: an empty pane of the
  workspace (the focused one first), otherwise a new workspace tab at the
  end of the tab bar. `open`, `openFiles` and `openLocalTerminal` all go
  through it when no pane is named; a drop on a pane and a move from
  another workspace name theirs (`paneForAdoptedSession` still splits).
  The owner asked for this on 2026-11-24: sessions open in tabs, arranging
  them is the user's business. Do not bring back automatic splits.
- A tab's title is the user's name for it (`customName`, set by Rename,
  cleared by an empty name), else its sessions' `tabTitle`s, else
  "Workspace N". `PaneContent.tabTitle` defaults to `title`; the SSH pane
  keeps to the connection's name because remote shells change the title
  with every prompt. Titles are refreshed from `onContentChange` and
  `onLayoutChange`.
- A workspace whose last pane is closed or lifted is told through
  `paneVC.onEmptied` and closes its tab on the next turn of the run loop,
  unless it is the only tab of its window. Everything that takes a pane
  out goes through `PaneContainerViewController.remove` (which keeps the
  focus rule below); `closePane` and `lift` report the emptiness. Empty
  panes the user split off keep a tab alive.
- Every workspace tab has a sidebar of its own. A new session's tab takes
  over the look of the one it was opened from
  (`matchSidebar(of:)`, `SidebarOutlineController.ViewState`: width,
  filter, open folders, selection, scroll position). While a filter is set
  every folder is open and `adopt` copies none; the outline must be tiled
  before it is scrolled or the scroll is cut short. Sidebars rebuild once
  per burst of model changes (10 ms debounce): `@Published` fires before
  the value changes, so the wait is also what lets the rebuild see the new
  lists, and with a dozen tabs the four lists of one store change used to
  mean four rebuilds in every one of them. `folderMoved` still rebuilds at
  once. Measured with 2,400 connections and 12 tabs: 6 ms a rebuild, 90 ms
  to open a tab.
- Local terminals are SwiftTerm's `LocalProcessTerminalView` (pseudo-
  terminal, output parsed on its I/O thread). Four things about it:
  it is its own terminal delegate and answers OSC 52 clipboard queries
  with the clipboard, so `LocalTerminalPolicy` sits in front as
  `terminalDelegate`, refuses that and forwards the rest (the property is
  weak; the pane holds the policy; do not remove it). Its `terminate()`
  sends SIGTERM, which an interactive shell ignores, so the pane sends
  SIGHUP first. The shell starts at the first layout (or after 0.5 s), so
  it knows its size before the first prompt. And the folder and the
  foreground program in the title come from the system, not from the
  shell: `tcgetpgrp` on the pseudo-terminal's descriptor, then
  `proc_pidinfo`, asked again after output (at most every 0.3 s). OSC 7 is
  ignored on purpose: a host reached with `ssh` sends its own paths.
  A title a program sets (OSC 0/2) replaces the composed one; if the shell
  was not in the foreground when it was set, it is dropped once the shell
  is back, so a tab does not keep the name of a host that was left.
  The shell is a login shell (`argv[0]` with a dash) from the account
  record; the environment is the app's without `TOOLBOX_*`.
- Updates are Sparkle 2 (`Updates.swift`, `bridge/update-config.sh`).
  What has to stay true:
  - The app takes an update only if the feed and the archive are both
    signed with the update key (`SURequireSignedFeed`,
    `SUVerifyUpdateBeforeExtraction`, `SUPublicEDKey` in the Info.plist
    that `bundle-app.sh` writes), with two exceptions that are Sparkle's
    own, there for a developer who lost the key. A copy that has seen no
    good feed for 20 days reads a badly signed one after all, with
    restrictions (no notes, no links, nothing downloaded before the user
    agrees). And an archive that fails the key is taken if the file
    itself is signed with the app's Developer ID team, which a disk image
    can be and a zip cannot. So the Developer ID's private key is a second
    key to updates, and a lost update key stops them for 20 days, not for
    good. The whole rule and the way back from a lost key (not tried) are
    in the 0.5.0 addendum of `docs/SECURITY-REVIEW.md`. Do not restate it
    from memory: the first write-up had it wrong.
  - The private half of the update key is in the login keychain of the
    release Mac, account `toolbox-update-key`; it is never in the
    repository or in a file a script writes. There is one key, and a
    second is made for nothing short of a lost one. `make release`
    compares the keychain's public half with the one in `update-config.sh`
    and stops on a difference.
  - The feed is `appcast.xml`, a file on every GitHub Release; copies read
    `releases/latest/download/appcast.xml`. A release published without it
    stops updates for everyone until the next one, silently, so `make
    publish` refuses to go on without a feed written for exactly that
    archive. The address is built into every copy: no renaming of the
    repository or the account without a build that knows the new address
    first.
  - In the bundle the framework is signed from the inside out (Autoupdate,
    Updater.app, then the framework), never with `--deep`, and its two XPC
    services are removed (they are for sandboxed apps; the app has none
    and no entitlements). SwiftPM leaves a search path into `App/.build`
    in the executable once a binary framework is linked;
    `bundle-app.sh` deletes it, or the release's check for paths from the
    build Mac fails.
  - A run against a test store does not start the updater (it would offer
    the real release to a test copy).
  - Things that cost time: Sparkle does not fetch `file://` feeds (hence
    the web server in the rehearsal), and plain HTTP needs the transport
    exception that only the rehearsal's copies get. Its "did extract"
    callback arrives before the signature is checked, so nothing may be
    logged or concluded there; "will install on quit" is the first point
    at which the update is verified. `generate_appcast` reads the key from
    the keychain and macOS asks about it once per Mac and per Sparkle
    version (Always Allow), which blocks an unattended `make release`
    until someone answers. `SwiftUI` has a `KeyPress` type too: do not
    name anything in the app that. What Sparkle does with a signature
    that fails is in its source and not all on its documentation page
    (`App/.build/checkouts/Sparkle`: `Sparkle/SUAppcastDriver.m`,
    `Autoupdate/AppInstaller.m`, `Sparkle/SUUpdateValidator.m`). A copy
    keeps the date of the first feed it refused in its preferences
    (`SUInitialFailedFeedSigningValidationDate`), which is why the
    rehearsal clears its copies' preferences before it starts; and
    `defaults delete` empties a domain but leaves an empty file in
    `~/Library/Preferences`.
- iTerm2 as the terminal engine was asked for (2026-11-24, "if that is
  open source and possible") and is not possible here. It is GPL (its
  README says version 3, its LICENSE file is version 2), which the
  proprietary license cannot take in, and it has no library form: Royal
  TSX's plugin is a modified copy of iTerm2's source built as a framework
  (`royalapplications/royaltsx-v6-oss`). The owner was told; do not start
  on it unless they come back to it knowing that.
- Anything that removes a pane must fix `focusedID` first:
  `rebuild()` synchronously calls `onLayoutChange` → toolbar validation →
  `focusedPane`. `closePane` does this; `focusedPane` repairs stale focus.
- `make core` after any Rust signature change; the Swift bindings are
  generated, not hand-edited.
- All IronRDP crates must be pinned to the same git revision or `picky`
  versions conflict. The RDP test server is not `Send`: it runs on its own
  thread with a current-thread runtime.
- RoyalVNCKit is a dylib dependency (by revision); `bundle-app.sh` copies
  it into `Contents/Frameworks` and adds the rpath.
- The echo test server must skip SFTP channels or it echoes SFTP INIT bytes.
  Its channel tables belong to one connection each (`new_client`): channel
  ids start over in every connection, and shared tables let sessions that
  opened together take each other's channel.
- Session end: `SshListener.on_closed(clean)` /
  `RdpListener.on_closed(reason, clean)`; a pane auto-closes 0.7 s after a
  clean end only. Failures keep the pane with the message.
- Releases (`make release`) need a "Developer ID Application" identity and
  a notarytool keychain profile `toolbox-notary`; README "Sharing builds
  with the team" has the setup. The Team ID is the code in parentheses in
  `security find-identity -v -p codesigning`; keep it, names and account
  emails out of the repo. On the desktop Mac both exist since 2026-11-18. The
  laptop has a Developer ID certificate of its own since 2026-11-19 (a
  second one for the same team) and, since 2026-11-24, the profile and
  `gh` (`brew install gh`, `gh auth login`); 0.4.0 was released from it.
  Lessons from the first real run: Xcode refused to
  create the certificate for the account holder, so it was made on
  developer.apple.com from a Keychain Access CSR; Apple's intermediates
  (DeveloperIDG2CA, AppleWWDRCAG3 from apple.com/certificateauthority) had
  to be imported before `security find-identity -v` listed the identity;
  notarization rejects signatures without a secure timestamp
  (`--timestamp`, only added when `TOOLBOX_HARDENED=1`); and never pipe
  into `grep -q` under `set -o pipefail` in these scripts, capture first.
  `make app` signs with the Developer ID too (no timestamp, no hardened
  runtime), which gives every build the same Keychain identity, so
  `make signing` is unnecessary on a Mac that has the Developer ID. Hardened runtime library validation needs
  the app and `libRoyalVNCKit.dylib` to share a Team ID, which Developer ID
  signing gives; ad-hoc rehearsals (`ALLOW_ADHOC=1 NOTARIZE=0`) add
  `App/Signing/rehearsal.entitlements` (disable-library-validation) to get
  past that, and real releases must never use it. No other entitlements are
  needed (not sandboxed).
- RDP desktop sizes go through `rdp_desktop_size` in the core (edges
  200...8192, height even, width a multiple of 4). `RdpSession` applies it
  on connect and resize, and `RdpSessionView.pixelSize()` calls the same
  function so the size it wants equals the size it gets. A width that is
  not a multiple of 4 makes the IronRDP test server (and some real
  servers) fail to encode the bitmap and drop the connection; that was the
  "connection lost" on Retina panes. Large frames arrive as several tiles,
  not one full-screen region. To see server-side errors in a test, add
  `tracing-subscriber` as a temporary dev-dependency and init it at DEBUG.
- RDP graphics. With `fast_graphics` the session offers the graphics
  pipeline (IronRDP's `GraphicsPipelineClient` on DRDYNVC, drained into the
  framebuffer by `ActiveStage::process`) and RemoteFX; without it the
  server is left with plain bitmap updates, which is what every version
  before 0.3.0 did and the fallback for a host that misbehaves. A pipeline
  resize arrives as a graphics reset that changes the image's size inside
  `process`, with no reactivation: the loop notices by comparing sizes
  after every PDU (`Presenter::present`). Advertise only codecs the build
  decodes: `client_codecs_capabilities(&[])` grows with cargo features that
  other crates switch on (the test server enables QOI), and a server sends
  what it is told the client takes; `remotefx_only()` cuts the list back.
  RemoteFX is lossy, so tests compare colours with a tolerance.
- RDP frames. The session thread copies changed regions into an IOSurface
  it creates (`FrameSurface`) and passes only the surface's ID to Swift,
  which finds it with `IOSurfaceLookup` (works inside the process; the
  surfaces are not global). A new desktop size means a new surface;
  `RdpSessionView` keeps the old one on screen until the first frame of
  the new one. `RdpBridge` counts surfaces so a refresh queued for the old
  one cannot run ahead of the news of the next, which would leave the new
  desktop unshown on an idle host. A layer only looks at a surface again
  when `contents` is set anew. Set the layer's frame inside a
  `CATransaction` with actions disabled, or it animates behind the window
  edge on every resize step. `copy_region` remains for tests only. A
  released surface's ID goes to the very next surface created, so a test
  cannot ask "is the old one gone" by looking its ID up (another test's
  surface answers); `surface_mark` in `tests/rdp_session.rs` puts a value
  on the surface first and looks for that.
- H.264 is decoded by `VideoToolboxDecoder` (hand-written FFI to
  VideoToolbox, CoreMedia, CoreVideo), synchronously, with no output
  format requested so the planes hold the stream's own samples; IronRDP
  applies the colour transform. No OpenH264 is linked, on purpose (built
  from source it has no patent cover, and it is C++ parsing server data).
  The frameworks are linked from `Package.swift` and `project.yml`.
- RDP clipboard. The CLIPRDR backend only forwards events; `ClipboardSync`
  in `rdp.rs` decides. Swift announces the pasteboard (`clipboard_offer`)
  only while the pane has the keyboard and remembers the pasteboard's
  change count; text is handed over only while that count is unchanged.
  Remote text is fetched only while the pane has the keyboard. Files:
  `initiate_file_copy` drops descriptors it dislikes, which would shift
  every index after them, so `build_file_offer` only produces names it
  accepts (see `windows_file_name`, the 259-unit limit). The remote names a
  file by its position in the list it was sent, never by path. Types that
  carry clipboard text are not `Debug`; keep it that way. A failed
  clipboard operation is logged and never ends the session.
- Each RDP session runs on its own thread with a current-thread runtime
  (`toolbox-rdp`), so decoding does not stall SSH sessions on the shared
  two-thread runtime.
- Release builds rewrite source paths (`--remap-path-prefix` in
  `build-core.sh`, `-file-prefix-map` in `bundle-app.sh`) and
  `release.sh` fails if the app still contains a path under the home
  folder. Debug builds are left alone so `make test` and `make core` do
  not rebuild each other's artifacts.
- Keychain access is keyed on the code signature; ad-hoc signatures change
  per build (see `make signing`). `VaultManager` re-owns the vault-key item
  when the signing certificate changes.
- SwiftUI `Picker` popups are lazy: the `NSPopUpButton` has no item titles
  until opened; `performClick` on it opens the menu for a screenshot.
- The workspace tab bar is private AppKit: `NSTabBar` is the hit-test view
  (tabs are not separate views), `NSTabBarNewTabButton` is the "+".
- `AuthKind` variants: `Password`, `KeyFile`, `Agent`, `Credential`,
  `StoredPassword` (secret in the vault under the connection id),
  `FolderCredential` (nearest folder's assignment; store keeps a path →
  credential map). Credential-based methods take the credential's username.
- `ConnectionKind`: `Ssh`, `Rdp`, `Vnc`, and File Transfer kinds `Sftp`,
  `Ftp`, `Ftps` (explicit `AUTH TLS`). File Transfer connections open the
  file browser (`SftpPaneView`/`SftpModel`), which talks to either
  `SftpSession` or `FtpSession` through the Swift `FileTransferSession`
  protocol; the two core objects must keep identical method signatures.
  `usesSsh` (ssh, sftp) decides key/agent auth; FTP uses username +
  password unsplit (`CredentialResolver.ftpAuth`).
- AD provider accounts typed into the provider are vault credentials with
  id `<providerId>#bind|admin|user`, folder = the provider's folder, tag
  `provider-account`. `AppModel.saveProvider(draft)` writes them before
  the provider, into the folder the provider is in at that moment (its
  save then moves them with the rest), and deletes ones no longer used;
  deleting the provider deletes them.
- One folder, one provider. The sidebar turns a folder path into a
  provider node with `providers.first { $0.folder == path }`, so a second
  provider in the same folder has no node (cannot be edited or deleted),
  keeps syncing, and everything it generates is listed beside the first
  one's: every AD computer twice. The store refuses that on every route
  (`checked_provider` for saves, `check_provider_folders` for
  `rename_folder` and `move_provider`), and the app calls
  `validate_provider` before writing typed-in accounts so a refusal leaves
  nothing in the vault. `separate_provider_folders` repairs older
  documents in `open` (the folder stays with the provider named after it,
  else with the first; any other gets `<location>/<its name>`, and is
  renamed `<name> 2` when that is taken or a neighbour has the name): in
  memory, the same way every time, saved by the next write. Do not write
  in `open`; a failed open makes the app move the store aside as broken.
- A provider's folder is its location plus its name (since 0.3.1).
  `checked_provider` sets the last component from the name on every save,
  so the `folder` a caller passes only says where the provider sits; a new
  name or location is `move_folder_contents`. `rename_folder` on a
  provider's own folder renames the provider (no menu does that today: a
  provider's node has Edit…, not Rename…). A name cannot hold `/`. The
  editor has Name and Location and nothing else (`ProviderDraft.parent`).
  Up to 0.3.0 the folder kept the name the provider was created with, so
  an older store can hold a folder named differently from its provider:
  nothing changes that at open, the next save or move of that provider
  does (`a_folder_from_an_older_version_takes_the_name_at_the_next_save`).
  A rename into a folder that exists merges the two. `sync_provider` looks
  the provider up again when the answer arrives: renamed or moved, the
  results go to its folder of then; deleted, they are dropped.
  `delete_provider` removes the folder when nothing else is in it, and a
  credential assigned to it.
- Sidebar expansion is AppKit's `autosaveExpandedItems`: an array of our
  node ids under `NSOutlineView Items <autosaveName>` in the preferences.
  Two things about it are in no documentation. AppKit looks the saved ids
  up the moment autosave is switched on, so that has to happen after the
  first `rebuild()` (end of `viewDidLoad`); switched on in `loadView` it
  finds nothing, and the first expand then overwrites the list, which is
  why 0.3.0 and earlier never reopened a folder. And it writes the list
  only when something is expanded or collapsed, whole. A folder node's id
  holds its path, so everything that renames or moves a folder or a
  provider must send `AppModel.folderMoved`:
  `SidebarOutlineController.folderMoved` hands the cached nodes on to the
  new path (they keep their expansion and selection) and rewrites the
  saved list.
- Every DC in the AD domain used for testing presents a 1024-bit RSA LDAPS
  certificate (checked 2026-11-16); macOS refuses those, so verified LDAPS
  cannot work there until they are reissued. The working provider
  uses "Accept untrusted certificates".

## Not verified against real infrastructure

A real Windows RDP host for anything new in 0.3.0: the graphics pipeline
(which codecs Windows picks, whether a resize comes as a graphics reset or
a reactivation, colours of real H.264), clipboard text, and pasting files
into Explorer. All of it is tested against IronRDP's server only. Also a
real VNC server and Touch ID on a certificate-signed build.

## Ideas not started

RDP: files from the remote desktop to the Mac, pictures on the clipboard,
audio, a client-side pointer (the host's cursor shapes; today the Mac's
arrow is all there is), ⌘C/⌘V mapped to Ctrl in a session, per-connection
certificate verification. Local terminals: entries in the tree with a name,
a folder to start in and a command (needs a security review first, see the
2026-11-24 addendum), entitlements so programs in a release build's
terminal can script other apps. Tabs: dragging a pane onto a pane of
another window, dragging a pane onto a tab. Elsewhere: session restore
(workspaces + layouts), broadcast input, jump hosts, port forwards, a
Tasks concept like Royal's, terminal theme picker. The sidebar keeps every
folder open after a filter was used and loses which ones were open before
(as it always did). Offered to the owner and not asked for:
LDAP hardening (plain-LDAP fallback off by default, a key-size hint in the
error, pinning an internal root CA); letting sidebar titles use the room
kept for the key badge and the spinner when neither shows (names are cut
38 points early in a narrow sidebar).

## Current state (update in every commit)

**Toolbox 0.5.0 (build 21) is published** as GitHub Release `v0.5.0`
(2026-11-24, from the laptop); the tag is on `f6a3e81`. It is the first
release with the updater in it, and so the last one anybody downloads by
hand: 0.4.0 and earlier cannot be told that it exists. The owner asked
what it would take for "the few users that have it, if any, to download
this version then get updates over the air", was given the answer
(Sparkle; one more download by hand; one key to keep safe), said to
proceed, and chose to release in the same session. Download counts on
GitHub that day: four per release for the disk images of 0.2.0 to 0.3.1,
the release checks and the owner's own installs included.

- The app: `Updates.swift` starts Sparkle's standard updater; Toolbox ▸
  Check for Updates… and Check for Updates Automatically (on by default:
  the owner's choice was "check daily but ask before installing"). The
  rules are in the invariants.
- The build: `bundle-app.sh` puts Sparkle.framework into the bundle, signs
  its helpers, writes the feed address and the public key into the
  Info.plist and removes SwiftPM's search path from the executable.
- Releases: `make release` signs the zip and writes
  `build/release/appcast.xml` with `generate_appcast`, then checks the
  archive's signature against the key in the built app with a few lines
  of CryptoKit; `make publish` uploads the feed and refuses to publish
  without one. `publish.sh` names the repository itself (`GH_REPO`), so
  the laptop clone's old remote address does not matter to it.
- The update key was made on the laptop that day with `generate_keys
  --account toolbox-update-key` and is in that Mac's login keychain only.
  **The desktop Mac cannot make a release until the key is brought over**
  (README, "Sharing builds with the team", step 3), and the owner was
  asked to keep a copy in their password manager. macOS asked about the
  key on the laptop at the first `make release` that used it, and the
  owner answered.

Before the release, on a debug build and on the release build (Developer
ID, hardened runtime): the rehearsal's checks; the update window in a
`--snapshot` picture with the 0.4.0 notes in it (Markdown, bold and
bullets as written); what a check sends, recorded on a local server (the
feed's path, `Toolbox/<version> Sparkle/2.10.1` and the language
setting); and that a run against the fixture does not start the updater.

The release itself. `make release`: signed, notarized (app and disk image
both accepted), stapled, the zip signed with the update key, the feed
written and its signature checked against the key in the app. Before
publishing, on a quarantined copy of the disk image: Gatekeeper accepts
the image and the app in it ("Notarized Developer ID"), the ticket is
stapled, hardened runtime, five executables and no entitlement on any, no
string naming the build Mac, Sparkle's license text in the bundle,
version 0.5.0 (21). The feed names
`releases/download/v0.5.0/Toolbox-0.5.0.zip`, build 21 and the zip's
length. The app copied out of the image ran against the fixture and the
local servers (SSH, RDP, a file browser and a local terminal, each in a
tab). The rehearsal passed against the notarized build.

After publishing: the four files downloaded back from the release match
`SHA256SUMS` and the local files byte for byte; the release is the latest
and not a draft; the feed served at
`releases/latest/download/appcast.xml` (two redirects) is the file that
was built. Then the nearest thing to a real update that can be had before
a second release exists: a copy of the release build, relabelled 0.4.9 (1)
with a bundle identifier of its own and signed again, was started against
the real feed with the real public key in it. It found 0.5.0 (21),
downloaded the published zip, verified it, and once it had quit the copy
on disk was the published app: the same 56 files as in the zip, signature
valid, ticket stapled, "Notarized Developer ID". Only the old copy's
version was made up.

**Corrected after the release: what Sparkle does when a signature
fails.** `f6a3e81`, and what the owner had been told, said that only the
update key gets an update installed and that a lost key ends updates for
good. Both were wrong, in opposite directions. The invariants and the
0.5.0 addendum of `docs/SECURITY-REVIEW.md` have it right now: 20 days,
then a restricted reading of the feed; a disk image signed with the
Developer ID in place of the key. A preference that a test copy left
behind led to it, Sparkle's source settled it, and one run showed it: 21
days on, the altered feed is offered in a window without notes, and
nothing is downloaded until the user says so. That run is the rehearsal's
fifth check now, and the rehearsal clears up after itself (it used to
leave 150 MB of test copies in `build/` and its copies' preferences and
caches in `~/Library`); it passed against the notarized build in that
form. In the app only a comment in `Updates.swift` changed: the
published build does what it did, and the description was what was off.
The owner was told. Left at Sparkle's default on purpose:
`SUSignedFeedFailureExpirationInterval`, where 0 would mean a badly
signed feed is never read and a lost key is final.

Not verified: an update between two published releases (the first real
one will be 0.5.0 to whatever comes next); an update of a copy in a
folder the user cannot write to; Check for Updates… as a click; what
follows Install Update for a feed read under the 20-day rule; the way
back from a lost key. `make test`: 72.

Afterwards, on the laptop: the app bundle was removed from `build/`, and
so were the scratch copies and what the test copies had left in
`~/Library`. `build/release/` (the 0.5.0 files) and the fixture
(`build/e2e`) are still there, as after 0.4.0: the rule the owner wrote
for the laptop is to delete the app bundle and leave the rest of `build/`
unless asked, and removing the whole folder, as the release flow at the
end of this file says, was refused by the session's permission mode then.
The owner can say which they want there. The copy in `/Applications` on
the laptop is still 0.2.0 and has no updater: 0.5.0 is installed from the
Releases page once, there as everywhere.

Found on the way and not done: the app ships Sparkle's license text and
no other third party's. SwiftTerm, RoyalVNCKit and the crates the core is
built from (its lock file lists 461, the test-only ones included) are MIT
or Apache-2.0 for the most part, with a few MPL-2.0 and Unicode-3.0, and
those licenses ask for their notice to travel with copies. Every release
so far is like that. A build step that collects the notices into
`Contents/Resources/Licenses` would settle it; the owner was told.

**Toolbox 0.4.0 (build 19)** was published earlier the same day as GitHub
Release `v0.4.0`; the tag is on `ae98388`. It was the first
release made on the laptop. Until that day the laptop had a Developer ID
certificate but neither a notarization profile nor the GitHub CLI. The
owner asked for the release from there: `gh` was installed and signed in
as the repository's owner (browser flow), and the `toolbox-notary` profile
was stored with `notarytool store-credentials` from the app-specific
password they supplied. Either Mac could release from then on; since
0.5.0 the desktop needs the update key first (above).

Built with `make release`: signed, notarized (app and disk image both
accepted), stapled. Checked before publishing, on a quarantined copy of
the disk image: Gatekeeper accepts the image and the app in it ("Notarized
Developer ID"), the ticket is stapled, hardened runtime, no entitlements,
no string naming the build Mac, version 0.4.0 (19). The app copied out of
that image then ran as a second instance against the fixture and the local
servers: SSH, RDP with the H.264 picture, a file browser and a local
terminal each in a tab, a typed command run by the shell, the merge into
one workspace, the new tab's sidebar. After publishing: the files
downloaded back from the release match `SHA256SUMS` and the local files
byte for byte, the release is the latest, and its tag points at the commit
it was built from. Afterwards the app bundle was removed from `build/` on
the laptop; what stayed there, and why, is in the 0.5.0 record above.

Two things learned on the way. A copy of the app taken out of a
quarantined disk image is quarantined too, and `open` starts such a copy
from a translocated path (`…/AppTranslocation/<id>/d/Toolbox.app`). It
did start, which is the nearest thing to a recipient's first launch that
was seen; but a script that looks for the path it launched neither reads
nor stops that instance, and three of them stayed on the owner's screen
until `pgrep -x Toolbox` showed them. For the run that is read from its
snapshot, clear the flag on the scratch copy first (`xattr -dr
com.apple.quarantine`); the Gatekeeper verdict comes from `spctl` on the
quarantined image and the app in it. And after any run `pgrep -x Toolbox`
has to come back empty, or with the owner's own copy only. `make publish`
was run as
`GH_REPO=tacticalbadger/Toolbox make publish`, because the laptop clone's
`origin` still names the old address and `gh` takes the repository from
the remote (`publish.sh` sets that itself since 0.5.0).

The 0.4.0 change set: the owner asked for three things in one message: a terminal
for local sessions "based on iTerm 2 if that is open source and possible",
a fix for "I can only paste into the filter from another source once",
and "new sessions for rdp, ssh, terminals, and ft should all open in tabs
instead of new panes; the user can then organize as they want or focus on
one session".

- **The paste bug.** Cause and fix are in the invariants (key
  equivalents): a live remote desktop took ⌘V from the whole window.
  Reproduced first with `--demo-filter-paste rdp-local` (first paste
  lands, second does not, the test server counts a key), isolated with the
  same run on an SSH connection (both land), fixed in
  `RdpSessionView.performKeyEquivalent`, run again (both land; the key
  count moves only when the pane has the keyboard). If the owner sees it
  again with no remote desktop in the window, it is something else.
- **Sessions in tabs.** See the invariants for where sessions go, tab
  titles, emptied tabs and sidebars. The Pane menu and the header's
  context menu are unchanged, except that Move to New Workspace is off for
  a session that already has its tab to itself. Rename takes an empty name
  to mean "automatic again".
- **Local terminals.** File ▸ New Local Terminal (⌘⇧T), a toolbar button,
  and a line in the empty pane's hint. Not iTerm2 (see the invariants):
  the SSH panes' engine in its local-process form. 10,000 lines of
  scrollback, title from the system, an idle shell closes without a
  question (`PaneContent.closeWarning`; the quit and close-window
  questions count `sessionsToWarnAbout`, not live sessions). Edit ▸ Find
  (⌘F, ⌘G, ⌘⇧G, ⌘E) drives SwiftTerm's find bar in SSH and local
  terminals. The folder purpose strings in `bundle-app.sh` and
  `project.yml` mention the terminal.
- `core/`: nothing that ships. The SSH test server (`ssh_test_server.rs`,
  `test-support` only) kept one channel table for all its connections,
  keyed by channel ids that start over in each one. With several sessions
  opened in one launch, which is now the normal way to check tabs, two
  SFTP sessions took each other's channel and one of them ended in "SFTP
  handshake failed: Timeout". Every client has tables of its own now.
  `make test`: 72 as before, clippy clean.

Verified on the finished build, as a second instance against the fixture
and the local servers, from logs and `--snapshot` reports: SSH, RDP, two
file browsers and a local terminal each in a tab named after it, in the
order opened; the sessions merged into one workspace by `--demo-merge`,
the emptied tabs closing; a tab closing when its shell exits; a line typed
into the local terminal run by a login shell; the title following `cd`
and a foreground program, a program's own title dropped when the shell is
back and the shell's kept; `--demo-filter-paste rdp-local` with the app in
front (both pastes land, one key at the server, the new tab's sidebar the
same on all five points); the menu items behind ⌘⇧T and ⌘F carried out by
`--demo-key` from the background (a terminal in a new tab; the find bar in
the snapshot picture); the local terminal in a copy signed ad hoc with the
hardened runtime, and no stray process after that copy is killed with a
program running in its terminal. `make test`: 72, clippy clean.

Seen in real screenshots on a build from earlier the same afternoon (the
last attempts could not get the app in front, and nothing that draws
changed in between): the tab bar with the sessions' names, the local
terminal's text and colours, three sessions side by side after a merge,
and output that arrived while a tab was hidden shown when the tab came
back, for an SSH and a local terminal.

Not verified: ⌘⇧T and ⌘F as key presses (the app could not be brought to
the front for that run; their items are set up like every other shortcut
in the menu), and anything that takes a click: the toolbar button, the
close question that names a program, Rename with an empty name, the find
bar's buttons. A notarized build. Real hosts: two sessions to one Windows
host with one account will behave like the test server, the earlier one
ends and its tab closes.

**This laptop's clone** was still on the history of the first rewrite of
2026-11-19 (11 commits with other IDs, differing from GitHub's in one
scrubbed hostname) and could not be pulled. `main` was moved to
`origin/main` with nothing merged and nothing lost. Left for the owner,
because it cannot be undone: the old commits are still in this clone's
reflog and under its local tag `v0.2.0` (GitHub's `v0.2.0` is a different
commit). `git fetch origin --tags --force`, `git reflog expire
--expire=now --all` and `git gc --prune=now` remove them; so does
deleting the clone and cloning again. Two more things about it. `origin`
still names the repository's old address. GitHub redirects fetches and
pushes, so the push went through it; `git remote set-url origin` with the
address at the top of this file puts it right (`make publish` does not
depend on it any more: `publish.sh` names the repository itself).
And its `user.email` is
still the old account's no-reply address, which has a name in it: the
commit was made with the identity of the newest commit on GitHub given on
the command line (`git -c user.name=… -c user.email=… commit`), and the
setting itself was left alone. Until the owner changes it, every commit
from this clone has to be made that way; compare with `git log -1
--format='%an <%ae>' origin/main` first.

**License, 2026-11-23, on the owner's word and pushed:** `LICENSE` added
(proprietary, see Conventions), a License section in `README.md`, and the
`license = "MIT"` line taken out of `core/toolbox-core/Cargo.toml`. No
code changed, so `make test` was not run for this commit; `cargo metadata`
still reads the manifest. It was made from a fresh clone, not from a
working copy: pull before other work.

As of 2026-11-23, on `main`. **Toolbox 0.3.1 (build 15) is published** as
GitHub Release `v0.3.1`; the tag is on `39fb7ea`. Built
with `make release` on the desktop Mac, notarized (app and disk image),
and checked from a quarantined copy of the DMG: accepted by Gatekeeper,
hardened runtime, no entitlements, no paths from the build Mac. The files
downloaded back from the release match `SHA256SUMS`. That copy of the app
then ran as a second instance against a fresh fixture and the local
servers: an RDP session showing the H.264 picture, an SSH pane, and the
provider-account, provider-rename and folder-rename aids, with the same
results as the debug build. The owner runs 0.3.0 from `/Applications`
until they install 0.3.1 from the Releases page. `build/` on the desktop
Mac was removed afterwards, as after every release from now on (see the
release flow at the end); the next session there starts with
`make core && make app`.

**0.3.1: providers and their folders.** The owner reported Active
Directory computers listed twice (screenshot, 2026-11-23, "trace and
resolve properly"), then asked for a provider's folder to follow its name,
for the version to be as close to perfect as it can be, and for a release.

- Cause of the duplicates: the owner's store holds two AD providers with
  the same name in the same folder. Nothing in the store stopped that, and
  the sidebar shows one provider per folder, so the second was invisible
  (no way to edit or delete it) while it kept syncing and its computers
  were listed beside the first one's. LDAP, the sync and the tree drawing
  were all fine. How the second one was created cannot be reconstructed;
  the likely route is a new provider whose name matched the first one's
  folder, which up to 0.3.0 could differ from the first one's name.
- One folder, one provider: enforced in `store.rs` on save, move and
  folder rename; `validate_provider` lets the app refuse before it writes
  typed-in accounts to the vault; `separate_provider_folders` puts
  existing stores right on open, nothing deleted.
- A provider's folder follows its name (see the invariants). The editor's
  hidden folder name is gone.
- Around it: deleting a provider tidies its empty folder and that folder's
  credential; a sync that ends after a rename, move or delete does the
  right thing, and its messages use the provider's name of then.
- Sidebar: checking renames showed that no version so far reopened the
  folders that were open (see the invariants). Fixed; open folders also
  survive a rename or a move, and a fixture run keeps its own record.
- Launch aids `--demo-provider-rename` and `--demo-folder-rename`.
- A test, not the app: `connects_renders_inputs_and_resizes` failed about
  one run in 25, and did so in the last `make test` before the release.
  It asked whether the old surface was gone after a resize by looking its
  ID up, and found another test's surface under that ID (see RDP frames).
  It marks the surface and looks for the mark now; the test binary passed
  80 times in a row afterwards.

Verified: 72 Rust tests (six new ones in the store, one of which replaces
an older one), clippy clean. In the app, as a second instance against
scratch fixtures, read from `--snapshot` pictures, the log and the store
file: a rename through the editor's draft of the 1Password provider (its
62 credentials move, the node and its subfolder stay open, the saved list
names the new path without anything being toggled, a relaunch reopens the
same tree) and of the AD provider with a typed-in bind account (the
account and the generated connections move); a name that leads to another
provider's folder refused before anything is written; a folder holding
both providers moved; a store with two providers in one folder opened
(two nodes, everything once, saved by the next sync); the tree reopened
from a list written by hand, a child listed before its parents included.
With the first fix: a copy of the installed 0.3.0 against such a fixture
shows one node with every computer twice, as in the owner's screenshot;
and against a copy of the owner's real store, counts only and nothing
written, nearly every generated computer twice before and none after.

Not verified: anything that takes a click (Save in the provider's sheet,
dragging a provider, the refusal as a dialog, the folder rename prompt);
those paths end in the same model calls the aids make. And nothing new
against real infrastructure.

**Left for the owner:** their store still has both providers. In 0.3.1
the stray one appears as a second node with ` 2` after its name;
right-click ▸ Delete removes it, its connections and its bind account.
Nothing was changed in their app data, with one exception: early fixture
runs on 2026-11-23, before fixture runs had a record of their own, wrote
fixture ids into the saved list of open folders in the app's preferences.
0.3.0 never read that list and replaces it at the next expand or
collapse; ids that match nothing are ignored. 0.3.1 will at worst start
with the folders closed once, as every version did until now.

The 0.3.0 change set (2026-11-20), asked for by the owner in one go:

- **RDP clipboard.** Text both ways; files and folders from the Mac to the
  remote desktop. `rdp_clipboard.rs`, `ClipboardSync` in `rdp.rs`, the
  clipboard part of `RdpSessionView`. Not done: files from the remote to
  the Mac, pictures.
- **RDP speed.** The owner found IronRDP slow next to Microsoft's client,
  resizing above all, and allowed replacing it. It stayed: the slowness
  was in how Toolbox used it. It offered the server no codec at all (plain
  bitmap updates), copied every changed region four times on the main
  thread, waited 300 ms after the last resize step, animated the layer
  behind the window edge, and blanked the pane at every new size. Now:
  graphics pipeline with H.264 through VideoToolbox, RemoteFX as fallback,
  the core painting straight into the displayed surface from the session's
  own thread, a resize request when the drag ends (80 ms after other
  layout changes), and the old picture kept until the new one is painted.
  View ▸ Remote Desktop has Retina Resolution, Fast Graphics and Share
  Clipboard switches.
- **Sidebar**: the "All Connections" and "All Credentials" groups are gone.
- **Credential picker**: a popover with a search field, in the connection
  editor, the folder credential sheet and the provider editor.
- **Releases no longer name the build Mac**: paths are rewritten and
  `make release` checks. The 0.2.0 download still contains them.
- README and CLAUDE.md pointed at the old repository address; fixed.

Verified for 0.3.0: 67 Rust tests (unit tests for the decoder against a stream from
the system encoder, the surface, file lists and ranges; 11 end-to-end RDP
tests covering plain updates, RemoteFX, the pipeline with H.264 and a
pipeline resize, clipboard text both ways, time-outs, files, refusals),
clippy clean, `cargo audit` as before. In the app against the local
servers, by `--snapshot` because the screen was locked: the pipeline
desktop with the decoded H.264 picture, a resize through `--demo-split`,
RemoteFX, plain updates, the picker filtering 62 credentials, the sidebar;
and with `--assume-keyboard`, clipboard text to and from the test server
and a file and a folder listed and read by it.

**Not verified: any of it against a real Windows host**, and not the
resize feel under a real drag (locked screen). First thing to check with
the owner: connect to a Windows host, drag-resize, copy text both ways,
paste a file into Explorer. If the picture is wrong or the session drops,
View ▸ Remote Desktop ▸ Fast Graphics off is the old behaviour; the pane
says so when a session fails. Retina Resolution off is the next lever for
speed (a quarter of the pixels).

Open questions left with the owner (from the 2026-11-19 clean-up): commit
author fields still carry a name and the old account's no-reply address;
the bundle identifier `com.dobbs.Toolbox`; whether to delete the 0.2.0
release, whose binary contains build paths. A Developer ID signature
names its holder by design.

Release flow: bump `VERSION`, add `docs/release-notes/<version>.md`
(shown on the release page and in the update window), commit and push,
`make release` (also signs the update and writes the feed; needs the
update key on that Mac), `make publish` (uploads the feed with the rest:
this is the moment installed copies start being offered the version), then
a commit that records the release here. **Then remove `build/`, every time, without
asking** (the owner's standing instruction since 2026-11-23: "always
remove builds after they're pushed to releases"; they install from the
Releases page). Do the checks that need the local files first: the
quarantined copy of the DMG, the download compared with the local file, a
run of the release build. The compile caches (`core/target`, `App/.build`)
stay.
