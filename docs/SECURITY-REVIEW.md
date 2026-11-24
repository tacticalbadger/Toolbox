# Security and bug review — 2026-11-13

Scope: the whole repository as of the phase 4 build (SSH, SFTP, RDP, VNC,
vault, credentials, 1Password and Active Directory providers). Method: a
read-through of every Rust and Swift source file, `cargo clippy` on all
targets, `cargo audit` on the dependency tree, and the end-to-end runs
against the in-process SSH and RDP servers.

## Fixed in this pass

| Area | Finding | Fix |
|---|---|---|
| Core | A panic while holding a mutex would poison it and turn every later lock into a crash | `lock_or_recover` recovers the guard everywhere the core locks |
| Core | Records holding passwords derived `Debug`, so a stray log line could print them | Redacting `Debug` impls for `SshAuth`, `RdpConfig`, `BindCredentials`, `Secret`, `ResolvedCredential` |
| Core | `connections.json` and `vault.json` were written with default permissions | Written as mode 0600 |
| SFTP | A hostile server could answer a listing with names like `../x` and steer a download outside the chosen folder | Core drops names containing `/`, NUL, `.` or `..`; the app only ever writes the last path component |
| SSH | No timeout on the authentication exchange, so a server that accepts TCP but never answers would hang the pane | 60 s auth timeout |
| Vault | If the owner check (Touch ID or password) was unavailable the vault unlocked anyway | Unlock now refuses with a reason |
| App | Closing a pane while its credentials were still being resolved left a connected "zombie" session with no UI | Terminal, RDP, VNC and SFTP panes ignore a late start after close |
| App | An unreadable store could crash the app at launch | Falls back to a temporary store with an alert |
| App | Passwords lingered in closed RDP/VNC views | Cleared on terminate |

## Reviewed and acceptable

- **Host keys.** Unknown keys prompt with the SHA-256 fingerprint and are
  recorded in `~/.ssh/known_hosts`; a changed key refuses to connect.
- **Secrets at rest.** Vault entries use XChaCha20-Poly1305 with a random
  nonce and the entry id as associated data; the key is random, lives in the
  login Keychain as this-device-only, and is held in memory behind
  `Zeroizing`. 1Password items are fetched at use time and never written.
- **Subprocess use.** The `op` CLI is run with an argument vector, never a
  shell, with user-configured vault and account names as separate arguments.
- **LDAP.** LDAPS first; the plain-LDAP fallback is a per-provider setting
  that defaults on to match the previous Royal TS script, and a sync that
  used it reports a warning. Certificate validation defaults on.
- **Remote content.** Terminal OSC 52 clipboard reads are denied; link
  opening is limited to http, https and mailto.
- **Logging.** No code path logs credentials; error messages carry host and
  user names only.

## Residual risks and known gaps

- **RDP server certificates are accepted without validation.** This matches
  the default of most RDP clients for self-signed hosts, and NLA (CredSSP)
  still binds the server's TLS key into the credential exchange, but a
  per-connection "verify certificate" setting is the right next step.
- **`rsa` crate advisory RUSTSEC-2023-0071 (medium).** Timing side channel in
  RSA private-key operations. It is reached only when authenticating with an
  RSA SSH key, the version is pinned by russh, and the fix ships with the
  crate's final release. Ed25519 keys are unaffected.
- **Unmaintained transitive crates** flagged by `cargo audit`:
  `atomic-polyfill`, `basic-toml`, `pin-utils`, `rustls-pemfile`. No known
  vulnerabilities; worth re-checking when upstreams move.
- **Secrets in Swift strings** (prompts, resolved passwords) cannot be
  zeroized; they are released as soon as the session starts.
- **VNC clipboard redirection is on by default**, as in Royal TS. Turn it off
  in `VncSessionView` if sharing the clipboard with a remote is unwanted.
- **No hardened runtime or sandbox yet.** The SwiftPM bundle is ad-hoc
  signed; enable the hardened runtime and a signing identity in the Xcode
  build before distributing.
- **Launch overrides** (`TOOLBOX_STORE_PATH`, `TOOLBOX_VAULT_PATH`,
  `TOOLBOX_KNOWN_HOSTS`, `--connect`, `--files`) exist for testing. They only
  affect the user's own process.

## Not covered

Live testing against a Windows RDP host, a real VNC server, an Active
Directory domain controller, and the Keychain/Touch ID unlock, none of which
are reachable from the development machine.

## Addendum — 2026-11-13, later the same day

Reviewed with the sidebar tree, pane arranging, workspace moves and
automatic pane close added.

- **Drag and drop** uses app-private pasteboard types carrying only node or
  pane ids; drops from other applications are ignored. Folder moves refuse a
  folder dropped into itself, and provider-generated items cannot be moved.
- **Folder paths** are normalized in the core (empty and whitespace-only
  components dropped), so the slash-separated paths in the store cannot
  contain empty segments; deleting a folder requires it to be empty.
- **Moving a pane between workspaces** re-parents the live view; the
  session's credentials are not touched or re-resolved, and the source pane
  is closed without terminating the session.
- **Automatic close** fires only on an end the core marks clean (remote
  logout or sign-out, or a close started here). Failures keep the pane with
  the error text, so a dropped connection cannot silently vanish.
- A crash was fixed where a split view acting as its own delegate recursed
  in AppKit; the delegate is now a separate object.

Verification: 33 core tests, clippy clean, `cargo audit` unchanged from the
morning (one advisory on the pinned `rsa` release candidate, four
unmaintained transitive crates), end-to-end runs for the three-pane layout,
the workspace move and the automatic close.

## Addendum — 2026-11-13, evening: Keychain prompts and code signing

The owner reported a second password dialog ("Toolbox wants to use your
confidential information stored in 'Toolbox vault key'") that came back even
after Always Allow. Cause: the SwiftPM bundle was signed ad hoc, so its
designated requirement was `cdhash H"…"`, which changes with every build, and
the Keychain stores Always Allow against exactly that requirement.

- **Stable signature.** `make app` now signs with a certificate when one
  exists (`TOOLBOX_SIGN_IDENTITY`, Developer ID Application, Apple
  Development, or the "Toolbox Local Signing" identity that `make signing`
  creates) and warns when it falls back to ad hoc. A certificate-based
  requirement (`identifier "com.dobbs.Toolbox" and certificate leaf = H"…"`)
  does not change between builds.
- **The local identity** is a self-signed certificate in the login keychain,
  trusted for code signing by the user in the one-time `make signing` step
  (macOS asks for the login password). It proves nothing to other Macs;
  Gatekeeper still treats the app as unidentified. It only gives the Keychain
  a stable name for the app. Distribution should use Developer ID plus
  notarization, which the script path already supports (hardened runtime
  and timestamp are added for Developer ID identities).
- **Re-owning the key.** When the signing certificate changes, VaultManager
  rewrites the vault-key item so the running build is its creator (staged
  copy, delete old, rename), so a single "Allow" is enough and the key is
  present in at least one item at every step. Ad-hoc builds skip this; they
  have nothing stable to bind to.
- **Rejected alternative.** An identifier-only designated requirement would
  have kept the prompt away for ad-hoc builds too, but any app claiming the
  bundle id could then read the key once the user had allowed it once.
- **Testing aids** added: `TOOLBOX_KEYCHAIN_SERVICE` (separate Keychain
  item, labelled with the service name), `--unlock-vault` (unlock at launch
  and log the outcome) and the standard `-vaultRequiresAuth NO` defaults
  override. They only affect the user's own process; the Touch ID gate is a
  user preference (menu toggle, UserDefaults) the user can change anyway.
- **Denied access** now reads "Access to the vault key in the Keychain was
  denied" instead of a raw status.

Verification: the ad-hoc build creates its own test item
(`TOOLBOX_KEYCHAIN_SERVICE`) and re-reads it on two further launches of the
same build without any SecurityAgent dialog ("vault unlocked" logged each
time). The certificate-signed path could not be exercised in this session
because `make signing` needs the user's login password for the trust step;
the first signed build will ask once for the existing item and must stay
quiet across rebuilds after that.

## Addendum — 2026-11-13, night: connection credentials and folder inheritance

- **Stored passwords.** A connection set to "Username and password" keeps the
  password in the vault under the connection's own id (same XChaCha20-Poly1305
  vault, same Touch ID gate); the store document still never holds a secret.
  Deleting the connection, or switching it to another method, removes the
  secret when the vault is unlocked; a locked vault leaves an orphaned entry
  that nothing references, as with deleted vault credentials.
- **Folder credentials** are a path → credential-id map in the store. The
  core validates the credential exists when assigning, drops assignments when
  the credential or folder is deleted, and carries them through renames.
  Resolution walks up from the connection's folder and ignores assignments
  whose credential no longer exists, so a stale mapping cannot resolve to
  the wrong account. Generated (AD) connections keep their explicit
  credentials; inheritance only applies to connections that opt in.
- **Testing aids** `--edit-connection` and `--set-folder-credential` open
  sheets in the user's own process and touch nothing else.
- Core tests: 35 pass (two new: folder inheritance across renames, deletes
  and reopen; auth-kind JSON round trip). End-to-end: a connection in a
  folder with a prompt-type credential asked for that credential's username;
  a stored-password connection with nothing in the vault reported it instead
  of connecting.

## Addendum — 2026-11-16: File Transfer connections and provider accounts

- **FTP** sends the password and file contents unencrypted. The editor
  labels it "FTP (not encrypted)" with a warning, and the browser's status
  line says so while connecting. SFTP and FTPS are offered first.
- **FTPS** verifies the server certificate with the system trust store.
  When verification fails the user sees the reason and decides; "Connect
  Anyway" keeps encryption but not server authentication, for that one
  connection only (nothing is remembered). Tests cover refuse, accept and
  pre-approved paths.
- **Listing names** from FTP servers get the same guard as SFTP: names
  containing `/`, NUL, `.` or `..` are dropped, so a hostile server cannot
  steer a download outside the chosen folder.
- **Provider-owned accounts** for AD are ordinary vault credentials (same
  encryption and Touch ID gate), removed with their secret when the
  provider stops using them or is deleted.
- **Active Directory finding**: every domain controller behind
  the AD domain used for testing presents a 1024-bit RSA certificate, which macOS
  refuses. Verified LDAPS is impossible until those are reissued; the
  "Accept untrusted certificates" option keeps the bind encrypted but
  unauthenticated, which is still far better than the plain-LDAP fallback
  (that sends the bind password in clear and defaults to on — flagged to
  the owner, not changed).
- `cargo audit` unchanged by the new crates (suppaftp, async-native-tls;
  libunftp only under `test-support`).

## Addendum — 2026-11-18: Developer ID releases

- Releases are signed with the Developer ID Application certificate,
  hardened runtime on, secure timestamp, notarized and stapled; the release
  script refuses to finish if the hardened runtime flag is missing and
  runs `spctl --assess` on the result.
- No entitlements are granted to release builds. In particular library
  validation stays on: only code signed by the same team (the bundled
  RoyalVNCKit) can load into the process. The
  `disable-library-validation` entitlement exists only for ad-hoc
  rehearsals and is applied only when the identity is ad hoc.
- Notarization credentials live in the login keychain (notarytool
  profile), never in the repository or scripts.
- Each colleague's data (store, vault, Keychain key) is created on their
  own Mac; the app bundle carries no connections or secrets.
- First release (0.2.0, 2026-11-18): signed with the owner's Developer ID,
  notarized and stapled; a quarantined copy of the DMG is
  accepted by Gatekeeper as "Notarized Developer ID" and carries no
  entitlements. The Developer ID private key exists only in the release
  Mac's login keychain and is not exportable from the repository's point
  of view: nothing about it is stored in git.


## Addendum — 2026-11-20: RDP clipboard sharing and the graphics pipeline

Reviewed: everything new in 0.3.0. The clipboard channel (CLIPRDR), the
graphics pipeline with H.264 through VideoToolbox, the surface the core
paints into, the searchable credential picker, and the new testing aids.
The adversary in mind is a hostile or compromised RDP host. Method: a
read-through of the whole change set, tests for the properties claimed
below, `cargo clippy`, `cargo audit`.

Result: nothing was found that lets a host reach beyond what the feature
hands it. Three things were changed because of the review (marked
"review" below). What remains is the risk that comes with sharing a
clipboard at all; it is spelled out so it can be weighed.

**What a remote desktop can read from the Mac.** With View ▸ Remote
Desktop ▸ Share Clipboard on (the default), a session is told what the
Mac's clipboard holds only while its pane has the keyboard (key window of
the active app, first responder). Sessions in the background are told
nothing.

- *Text.* The announcement carries no content. The text is handed over
  when the host asks for it, and only while the clipboard still holds what
  was announced: something copied later in another app was never offered,
  and a request for it is refused. A host does not have to wait for the
  user to paste, though; it can ask the moment it is told. **Anything on
  the clipboard when you click into a remote desktop, and anything you
  copy while working in one, is readable by that host**, passwords copied
  from a password manager included. That is how every RDP client's
  clipboard works; Toolbox narrows it to the session in front.
- *Files.* When files or folders are on the clipboard the session
  announces a list of names and sizes. The host then asks for byte ranges
  by position in that list. It never supplies a path, so it cannot name a
  file that was not copied. Folders are walked without following links out
  of them; a copied link means its target. Names are rewritten to be
  plain Windows file names (no separators, no `..`, no device names), so a
  Mac file name cannot be read as a path on the other side, and no path on
  the Mac is sent. Limits: 5,000 entries and 32 levels per copy, 16 MiB
  per range, 8 ranges at a time. As with text, the host can read the
  offered files without anyone pasting.
- *Review:* a file is served only while its path still resolves to
  itself. If a link is put in the file's place, or in a folder above it,
  after the list was built, the request is refused. This matters for
  folders other people can write to, such as a network share.
- A host may lock a file list so a paste in progress survives the next
  copy. A locked list that is no longer on the clipboard is forgotten
  after 60 seconds without a read.
- macOS may ask once whether Toolbox may read Desktop, Documents or
  Downloads when a file from there is first offered. The purpose text
  says why.

**What a remote desktop can do to the Mac.** It can put text on the
Mac's clipboard while its pane has the keyboard, or the next time it has,
provided the Mac's clipboard did not change in between. Text only, at
most 32 MiB; nothing is written to disk or run. The residual risk is
paste-jacking: a compromised host can swap the clipboard just before you
paste somewhere else. Files and pictures from the host are not accepted.

**Protocol input.**
- *Review:* one message on the clipboard channel is limited to 64 MiB.
  IronRDP's default has no limit, and a host could have made the session
  buffer gigabytes.
- Graphics pipeline data is decoded by IronRDP in Rust (ClearCodec,
  RemoteFX Progressive, planar). H.264 goes to the system's VideoToolbox;
  no decoder library is bundled. The wrapper checks the geometry of every
  decoded picture before reading it, and tests feed it truncated and
  corrupted streams. A picture that fails to decode is dropped and the
  session carries on.
- *Review (found by a test):* the session advertised every bitmap codec
  IronRDP knew, including ones it was not built to decode. It now
  advertises RemoteFX only.
- The desktop lives in an IOSurface found by ID inside the app. Such
  surfaces are not global, so another process cannot look one up.
- Clipboard text is never logged, and the types that carry it are not
  printable.

**Unchanged, and worth knowing now that more flows over a session.** RDP
still accepts any server certificate. Network Level Authentication is
always required and ties the logon to the server's TLS key, so someone in
the middle who does not know the account's password cannot complete the
logon. Certificate checking per connection stays on the list.

**Testing aids.** `--assume-keyboard` drops the keyboard condition for
clipboard announcements and `--snapshot <dir>` writes pictures of the
app's windows. Both exist only as launch arguments, for checks that have
to run with the screen locked.

**Releases.** The binary of 0.2.0 contained about 1,100 source paths
under the build Mac's home folder. Release builds now rewrite them, and
`make release` stops if any are left in the app or its bundled library.

**Dependencies.** No new third-party crate ships: `ironrdp-cliprdr` and
`ironrdp-egfx` come from the IronRDP revision already pinned, and nothing
in C or C++ was added. `cargo audit` reports what it did before this
change set: the `rsa` advisory, the unmaintained crates, and a group of
"unsound" advisories for `heapless` published on 2026-11-18, reached
through the smart-card support of IronRDP's `sspi`, which Toolbox does
not use.

**Not verified.** None of this has run against a real Windows host yet.
The properties above are tested against the in-process IronRDP server
(67 Rust tests) and in the app against the local test server. If a host
misbehaves with the newer graphics, View ▸ Remote Desktop ▸ Fast Graphics
switches them off.


## Addendum — 2026-11-23: providers and their folders (0.3.1)

- **Finding.** The store accepted a provider whose folder already belonged
  to another provider. The sidebar shows a provider as its folder, one per
  folder, so the second had no node of its own: it could not be edited or
  deleted, while it kept refreshing on its timer, binding to the directory
  with the account stored for it, and listing every computer next to the
  first provider's copy. Nothing left the Mac that would not have anyway,
  but a stored account was in use with no place in the app to see or
  remove it.
- **Fixed.** The core refuses any save, move or folder rename that would
  put a provider in a folder another provider owns, and says which
  provider that is. The app asks the store before it writes the accounts
  typed into a provider, so a refused provider leaves no credential and no
  secret behind in the vault.
- **Existing stores.** A document that already has two providers in one
  folder is separated when opened. The folder stays with the provider it
  is named after, or else with the first; any other gets a folder of its
  own next to it, named after that provider (its name gains a 2, or the
  next free number, when the name leads to a folder in use or is a
  neighbouring provider's too), with what it generated and the accounts
  typed into it. A credential assigned to the shared folder is assigned to
  the new one as well, so a connection that inherited it resolves the same
  credential as before and none gains one it did not have. Records only
  change folder; nothing is deleted, vault ids stay the same and no secret
  is read. Deleting the provider from there removes its connections, its
  accounts and their secrets, as for any provider.
- **A provider's folder follows its name** (new in 0.3.1). The folder is
  the provider's location plus its name, set by the core on every save, so
  the tree cannot show one thing and the store hold another. A rename
  moves the folder with everything inside, credential assignments of the
  folder and its subfolders included: what a connection inherits does not
  change. Renaming into a folder that exists merges the two, as renaming a
  plain folder always did; an assignment on the moved folder then replaces
  the other folder's. A name cannot contain “/”.
- **Leftovers.** Deleting a provider now removes its folder when nothing
  else is in it, together with a credential assigned to that folder; until
  now the assignment stayed behind, invisible, and would have applied to
  the next folder created under that name. A refresh that ends after its
  provider was deleted adds nothing (it used to leave what it fetched in
  the store with no provider to remove it), and one that ends after a
  rename or move files its results where the provider is by then.
- **Sidebar state.** Which folders are open is kept in the app's
  preferences as a list of node ids: folder paths and provider ids, no
  hostnames from connections, no usernames, no secrets. A run against
  another store (`TOOLBOX_STORE_PATH`) keeps its own list.
- Tests: 72 Rust tests. The store's cover the refusals (new provider,
  new location, move, folder rename), the separation on open, the folder
  following the name, a store from an older version,
  the folder credential on delete, and refreshes that end after a rename
  or a delete.

## Addendum — 2026-11-24: shortcuts beside a remote desktop, sessions in tabs, local terminals (0.4.0)

Reviewed: the fix for keyboard shortcuts in a window that holds a live
remote desktop, the change that gives every session a tab of its own, and
the new local terminal pane. Nothing in the core that ships changed: no
protocol, vault or store code. (The SSH test server, built only with the
`test-support` feature, was mixing up connections that opened at the same
moment and no longer does.) Method: a read-through of the change set and of the
parts of SwiftTerm the local terminal relies on (its local-process view,
its clipboard hooks, its check of links), and runs against the local test
servers with the launch aids named below.

**Shortcuts pressed elsewhere in the window went to the remote desktop
(found, fixed).**

- Up to 0.3.1 a live RDP pane took every ⌘ shortcut pressed anywhere in
  its window, except the ones that manage panes and workspaces. AppKit
  offers a key equivalent to every view in the key window before the menu
  sees it, and the pane did not check that it had the keyboard.
- On the Mac: ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z did nothing in the sidebar's filter
  while a remote desktop was live in the same window. This is what the
  owner reported as "I can only paste into the filter once": once, before
  the session.
- On the host: each of those shortcuts arrived as a press of its letter,
  with no modifier (the ⌘ key itself had gone to the field on the Mac) and
  no release, typed into whatever had the keyboard there. No clipboard
  content went with it. The clipboard is announced only while the pane has
  the keyboard, and that rule was not affected.
- Fixed: the pane takes a shortcut only while it is the first responder.
  SwiftTerm's and RoyalVNCKit's views already checked.
- `--demo-filter-paste <connection>` presses ⌘V the way the keyboard
  would, with the keyboard in the filter before and after the session
  opens and then in the session's pane, and logs where it went; the RDP
  test server counts the keys it receives. Before the fix the second paste
  never reached the field and the server counted a key. After it both
  pastes land, the server counts nothing until the pane has the keyboard,
  and then counts the one key that is the session's. With an SSH session
  the pastes landed before and after.

**Local terminals.** File ▸ New Local Terminal runs a shell on the Mac,
which the app could not do before.

- *What runs.* The login shell named in the user's account record
  (`/bin/zsh` when that is not an executable file), as a login shell, in
  the home folder, as the user. Nothing is elevated. The app is not
  sandboxed, so the shell can do what a shell in Terminal can.
- *What cannot start one.* Only the menu item, its shortcut and the
  toolbar button. There is no connection kind for it, so nothing in a
  store document names a program to run and a provider cannot generate
  one. Keep it that way unless stored commands get a review of their own:
  they would turn the store, and whatever a provider syncs into it, into
  something that executes. The testing aid that types into a terminal
  (`--demo-type`) is ignored unless the run names its own store in the
  environment.
- *Environment.* The app's own, without the `TOOLBOX_*` overrides of a
  test run, plus `TERM`, `COLORTERM`, `TERM_PROGRAM` and a UTF-8 `LANG`
  when no locale is set. The app never puts a secret into its environment
  (the vault key stays in the Keychain; secrets from the vault or
  1Password are handed to the core in memory at connect time), so the
  shell inherits none.
- *Reading the clipboard is refused.* SwiftTerm's local-process view
  answers a clipboard query (OSC 52 with `?`) with the clipboard's text.
  Left as it comes, anything that can print to the terminal could ask: a
  file shown with `cat`, a host at the other end of `ssh`. Toolbox puts a
  delegate in front of the view that refuses the query, as the SSH panes
  always have. Writing to the clipboard (OSC 52 with data) stays allowed,
  as in SSH panes; the residual risk is the same one, that output can
  replace what you are about to paste somewhere else. The newer clipboard
  protocol (OSC 5522) is answered as unsupported.
- *Links.* A click on a link in terminal output goes through SwiftTerm's
  check: web and mail links open; a local file or folder opens only if it
  exists and cannot run code; any other scheme asks first and shows the
  target; text with invisible characters is refused.
- *Closing.* Closing the pane hangs up the shell (SIGHUP, which a shell
  passes on to its jobs), then SIGTERM; SwiftTerm kills what is left when
  the pane is released. A program in the foreground is named in a question
  first. An idle shell closes without one, and background jobs end with it
  unasked, as they do when a Terminal window closes.
- *What stays behind.* Scrollback (10,000 lines) lives in memory and goes
  with the pane. Nothing is written to disk; SwiftTerm's host logging is
  not switched on.
- *Privacy prompts.* A program started in the terminal is Toolbox as far
  as macOS privacy is concerned. The first `ls ~/Documents` asks whether
  Toolbox may read Documents, and the purpose text now says that a local
  terminal is one of the reasons. The answer covers the whole app, which
  could already read those folders when asked to (file transfer, files
  pasted into a remote desktop).
- *Find.* ⌘F searches inside the process. ⌘E (Use Selection for Find)
  puts the selection on the system's find pasteboard, which other apps
  read, as it does in every Mac app.

**Sessions in tabs.**

- More windows, each with a sidebar; no new data flows. A new tab's
  sidebar starts with the filter, open folders, selection and scroll
  position of the one the session was opened from: the same information,
  in the same process.
- A tab is named after its sessions: connection names, and for a local
  terminal the folder it is in and the program in the foreground. Window
  titles show in the Window menu, in Mission Control and to anything
  allowed to list windows. Tabs used to be called "Workspace 1" unless
  renamed, with the names only in pane headers. Worth knowing when sharing
  a screen; renaming a tab replaces the automatic name.
- The clipboard rule for remote desktops is unchanged. With one session
  per tab, a desktop in another tab is in a window that is not the key
  window and is told nothing.
- A tab closes by itself only when no session is left in it. A session
  that failed keeps its pane, its message and its tab.

Not verified: a notarized release build of this change set (the checks ran
on debug builds, and on a copy signed ad hoc with the hardened runtime for
the local terminal alone). In a release build programs in the terminal
should be unable to script other apps or use the camera or microphone,
because the hardened runtime wants entitlements for those and the release
has none; that is what other terminal apps ran into, and it was not tried
here.

Tests: 72 Rust tests as before, none new, clippy clean. The app paths
above were run against the local test servers and read from logs,
`--snapshot` reports and screenshots.
