# Toolbox — working notes for Claude

Read this first on any Mac. It is the handoff between the two machines this
app is developed on; memory files do not travel, this file does.
**Update the "Current state" section at the end in every commit** (write it
before committing, so the commit describes itself).

## What this is

Toolbox is a macOS native replacement for Termius + Royal TSX for the owner
(uses Termius, Royal TSX and 1Password daily; prefers Rust).
SSH terminals in tabbed workspaces with split panes, RDP and VNC with
dynamic resolution, connection objects in a Royal-style folder tree, a
credential vault with Touch ID, SSH key identities, and dynamic folders fed
by 1Password (`op` CLI) and Active Directory. Royal TS reference material
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
- `App/` — SwiftPM package. AppKit shell: `App/` (delegate, menu),
  `Workspace/` (window = workspace tab, `PaneContainerViewController`,
  `PaneView`, `PaneLayout`), `Terminal/` (SwiftTerm), `Remote/` (RDP via
  IOSurface layer plus clipboard sharing, VNC via RoyalVNCKit), `Files/`
  (SFTP browser, SwiftUI), `Sidebar/` (NSOutlineView tree, SwiftUI editors,
  `CredentialPicker.swift` with the search popover), `Model/` (AppModel,
  VaultManager, CredentialResolver, ProviderSync), `Support/`
  (`Snapshot.swift`: the `--snapshot` aid). `Sources/Generated/` and
  `Vendor/` are produced by `make core` and gitignored.
- `bridge/` — build scripts: `build-core.sh`, `bundle-app.sh`,
  `signing-identity.sh`, `release.sh` (`make release`), `publish.sh`
  (`make publish`: GitHub Release with the notarized DMG), `make-icon.swift`.
  `VERSION` holds the marketing version; the build number is the commit
  count.
- `tools/e2e/` — end-to-end harness (fixture, test servers, launch,
  capture). `docs/SECURITY-REVIEW.md` — review findings and addenda.

## First time on a Mac

The full dependency table is in README.md ("Dependencies"). In short:

1. Apple silicon Mac, macOS 14+. Xcode at `/Applications/Xcode.app`
   (built with 27.2; the SwiftUI macro plugin is borrowed from it, the
   license need not be accepted for `make app`) and the Command Line Tools
   (`xcode-select -p` should print `/Library/Developer/CommandLineTools`;
   the scripts unset `DEVELOPER_DIR`).
2. Rust via rustup, stable (built with 1.100). Network on first build:
   crates.io, IronRDP from GitHub, SwiftTerm and RoyalVNCKit via SwiftPM.
3. Optional: `brew install 1password-cli` (providers), `brew install
   xcodegen` (`make xcode`, needs `sudo xcodebuild -license accept`),
   `cargo install cargo-audit`, `brew install gh`.
4. `make core` then `make app` → `build/Toolbox.app`. `make test` → Rust
   tests (72 as of 2026-11-23). `make run` launches the bundle.
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

Launch args: `--connect <id>` / `--files <id>` (repeatable), `--expand-all`,
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

Screenshots need Screen Recording permission for the terminal; GUI
scripting (clicks) is not available without Accessibility permission, so
UI paths are exercised with launch aids or synthetic `NSEvent`s posted from
inside the app. Crash reports land in `~/Library/Logs/DiagnosticReports/`
as `Toolbox-*.ips` (JSON: header line, then body with `threads[].frames`).

## Conventions

- Commit only when the owner asks, on `main`. Commit messages end with the
  co-author line the session's Claude Code harness specifies (currently
  `Co-Authored-By: Claude <noreply@anthropic.com>`); PR bodies with
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
- Session end: `SshListener.on_closed(clean)` /
  `RdpListener.on_closed(reason, clean)`; a pane auto-closes 0.7 s after a
  clean end only. Failures keep the pane with the message.
- Releases (`make release`) need a "Developer ID Application" identity and
  a notarytool keychain profile `toolbox-notary`; README "Sharing builds
  with the team" has the setup. The Team ID is the code in parentheses in
  `security find-identity -v -p codesigning`; keep it, names and account
  emails out of the repo. On the desktop Mac both exist since 2026-11-18; the private
  key lives only in that Mac's login keychain (export a .p12 to release
  from the laptop). Lessons from the first real run: Xcode refused to
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
certificate verification. Elsewhere: session restore (workspaces +
layouts), broadcast input, jump hosts, port forwards, a Tasks concept like
Royal's, terminal theme picker. Offered to the owner and not asked for:
LDAP hardening (plain-LDAP fallback off by default, a key-size hint in the
error, pinning an internal root CA); letting sidebar titles use the room
kept for the key badge and the spinner when neither shows (names are cut
38 points early in a narrow sidebar).

## Current state (update in every commit)

As of 2026-11-23, on `main`. **Toolbox 0.3.1 (build 15) is published** as
GitHub Release `v0.3.1`; the tag is on the commit before this one. Built
with `make release` on the desktop Mac, notarized (app and disk image),
and checked from a quarantined copy of the DMG: accepted by Gatekeeper,
hardened runtime, no entitlements, no paths from the build Mac. The files
downloaded back from the release match `SHA256SUMS`. That copy of the app
then ran as a second instance against a fresh fixture and the local
servers: an RDP session showing the H.264 picture, an SSH pane, and the
provider-account, provider-rename and folder-rename aids, with the same
results as the debug build. The owner runs 0.3.0 from `/Applications`
until they install 0.3.1 from the Releases page; `build/` on the desktop
Mac holds the release build and can go.

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

Release flow, unchanged: bump `VERSION`, add
`docs/release-notes/<version>.md`, commit and push, `make release`,
`make publish`, then a commit that records the release here. The owner installs from the Releases page; nothing needs
to stay in `build/`.
