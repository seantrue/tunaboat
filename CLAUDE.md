# Tunaboat

An SSH tunnel manager for macOS: a menu bar app plus a `tunaboat` CLI, sharing one core library.

Renamed from `tmon`; the Swift modules are `TunaboatCore` / `TunaboatApp`, the CLI is `tunaboat`,
and the app bundle is `Tunaboat.app` (`dev.impressionist.tunaboat`). Configuration moved to
`~/.config/tunaboat/tunnels.json`; `ConfigStore` still reads `~/.config/tmon/tunnels.json` when
the new path has no file, so an existing installation keeps its tunnels. The old file is never
written to or deleted.

> **Status: working.** `TunaboatCore`, the `tunaboat` CLI and the menu bar app are implemented, with
> 108 tests in 19 suites, all passing. Verified end to end against a real host: forwards established
> and carrying traffic, plus the port-collision, host-key, DNS-failure and inherited-forward paths.
> Developer ID signing and notarisation work (`Scripts/bundle-app.sh --sign` / `--notarize`), and
> launch-at-login is registered through `SMAppService` — see *Launch at login*.
>
> When code contradicts this file, the code wins — update this file in the same change.

## Decisions already made

| Question | Decision |
|---|---|
| Shape | Menu bar app **and** a CLI, over a shared `TunaboatCore` library |
| Build | Swift Package Manager (`Package.swift`), no `.xcodeproj` |
| Tunnels | Spawn `/usr/bin/ssh` as a subprocess — **not** a native SSH stack |

### Why spawn `/usr/bin/ssh`

Delegating to the system binary inherits `~/.ssh/config` (incl. `Host` aliases, `ProxyJump`,
`IdentityFile`), the ssh-agent, Keychain-stored passphrases, and `known_hosts` handling. A native
stack (SwiftNIO SSH, libssh2) would mean reimplementing all of it. The cost is that tunnel state
must be inferred from process liveness, stderr, and port probes rather than read from an API —
see *Tunnel lifecycle* below. Do not "simplify" this by switching to an in-process SSH library
without an explicit decision from the maintainer.

## Toolchain

- Swift 6.3 / Xcode 26.6; the local toolchain targets `arm64-apple-macosx26.0`
- `Package.swift` declares `swift-tools-version: 6.0` and a `.macOS(.v14)` deployment target —
  the floor the app must keep building against, not the SDK it happens to be compiled with here.
- Swift 6 language mode (implied by the tools version) with strict concurrency. Model actors
  deliberately; do not silence data-race diagnostics with `@unchecked Sendable` or
  `nonisolated(unsafe)` to make a build pass.
- The only external dependency is `swift-argument-parser`, used by the CLI target alone.

## Commands

```sh
swift build                     # debug build of every target
swift build -c release
swift run tunaboat <args>           # exercise the CLI
swift test                      # full suite
swift test --filter SSHOutputParserTests   # one suite
```

CLI subcommands: `list`, `show` (prints the ssh command a spec would run), `up` (foreground run
with live status), `import` (from tynsoe's SSH Tunnel Manager, with `--dry-run`). Every subcommand
takes `--config <path>`.

```sh
./Scripts/bundle-app.sh release              # ad-hoc signed, local use
./Scripts/bundle-app.sh release --sign       # Developer ID, hardened runtime, timestamped
./Scripts/bundle-app.sh release --notarize   # …then submit to Apple, staple, verify
./Scripts/bundle-app.sh release --notarize --universal   # arm64 + x86_64, for distribution
open .build/Tunaboat.app

./Scripts/make-dmg.sh --skip-build --notarize # distributable .dmg from the built app
```

If a build fails with `precompiled file … was compiled with module cache path …` naming a
directory that no longer exists, `.build` is stale from before the `tmon` → `tunaboat` rename;
`rm -rf .build` (or just its `ModuleCache`) fixes it. Nothing is wrong with the source.

`swift run TunaboatApp` launches the UI without a bundle, but a menu bar app needs an Info.plist
(`LSUIElement`, bundle id) before AppKit treats it as a real app, so use the bundle script.

### Signing and distribution

**No credentials live in this repo, and none should.** Signing uses the `Developer ID Application:
Sean True (78DGVG7MYU)` identity already in the login keychain; notarisation uses a `notarytool`
keychain profile. Overridable with `TUNABOAT_TEAM_ID` and `TUNABOAT_NOTARY_PROFILE`. The same
approach as the sibling `pursuit` project, which is where the identity and team came from.

The profile must be created once, and requires an app-specific password from appleid.apple.com:

```sh
xcrun notarytool store-credentials tunaboat-notary \
    --apple-id <apple-id> --team-id 78DGVG7MYU --password <app-specific-password>
```

Two things the script gets right that are easy to get wrong:

- **Sign inner executables before the bundle.** `codesign` seals what a bundle contains, so
  signing anything inside it afterwards invalidates the outer signature.
- **The CLI goes in `Contents/Helpers/tunaboat`, never `Contents/MacOS/`.** The filesystem is
  case-insensitive, so `MacOS/tunaboat` and `MacOS/Tunaboat` are the *same file* and the CLI
  silently overwrites the app binary — the bundle then launches into CLI help text.

#### The disk image

`Scripts/make-dmg.sh` packages `.build/Tunaboat.app` into `.build/Tunaboat-<version>.dmg` with a
symlink to `/Applications` beside it as the drag target, then signs the image and optionally
notarises and staples it.

- **Notarise the app first, then pass `--skip-build`.** The script's default path re-signs the app,
  and re-signing *discards the stapled ticket*. The correct order is
  `bundle-app.sh release --notarize` (staples the app) followed by
  `make-dmg.sh --skip-build --notarize` (staples the image). Both matter: the image's ticket covers
  the download, and the app's own ticket is what validates a copy dragged out of it onto a machine
  that is offline or has never seen it.
- The Finder layout is set by AppleScript against a mounted read/write image, which needs an
  Automation permission and a GUI session. It is deliberately **never fatal** — without it the
  icons are simply unarranged, and the `/Applications` drop target still works.
- **`spctl -a` reports a confusing rejection for a disk image**, because it assesses it as an
  executable. `spctl -a -t open --context context:primary-signature` is the assessment a
  double-clicked image actually gets, and is what the script prints.

**Anything handed to someone else must be built `--universal`.** A plain `swift build` targets
only the machine doing the building, so a release cut on Apple silicon will not launch at all on
an Intel Mac — there is no Rosetta fallback for an absent slice. `v0.1.0` shipped arm64-only for
exactly this reason. The arch flags have to reach `--show-bin-path` as well as the build itself:
a universal build lands in `.build/apple/Products/Release` rather than the per-arch directory, and
without them the script would happily sign whatever single-arch binaries were left over from a
previous run. `bundle-app.sh` prints `lipo -archs` for both binaries afterwards and fails if
`--universal` did not take effect, and `make-dmg.sh` warns when packaging an arm64-only app.

**Version strings come from git, and the fallback lied.** `git describe --tags --always` returned
`0.1.0` only because the repo had neither tags nor commits, so the fallback fired; the first commit
silently turned `CFBundleShortVersionString` into a bare hash (`30069bc`), which is what the app
then reported as its version. It now reads the marketing version from a `v[0-9]*` tag with a
literal `0.1.0` fallback, and `CFBundleVersion` from `git rev-list --count HEAD`, which is numeric
and increases. Tag a release `v0.2.0` and both follow.

`--options runtime` (hardened runtime) and `--timestamp` are both required for notarisation.
Tunaboat is not sandboxed, so it needs no entitlements; it reads `~/.ssh/config` and spawns
`/usr/bin/ssh`, and sandboxing it later would require revisiting both.

## Layout

```
Package.swift
Sources/
  TunaboatCore/     # tunnel model, config parsing, ssh process supervision — all logic lives here
  tunaboat/         # CLI front end (swift-argument-parser) — lowercase, matching the executable
  TunaboatApp/      # MenuBarExtra UI
Tests/
  TunaboatCoreTests/
claude-debug/   # scratch scripts and fixtures (see below)
```

Keep `TunaboatCore` free of AppKit/SwiftUI imports. Both front ends are thin; if a behavior is worth
testing it belongs in the library, because only the library is testable from `swift test`. Naming
and port-conflict rules live in `TunaboatCore` for exactly this reason, even though only the UI uses
them.

### Seeing the UI

The GUI cannot be inspected from a terminal, so verification uses two tools rather than guesswork:

- `claude-debug/list-app-windows.swift` — lists on-screen windows owned by the app with their
  bounds, confirming a window actually rendered. It deliberately does not read window titles,
  since `kCGWindowName` needs Screen Recording permission while owner and bounds do not.
- `TUNABOAT_RENDER_PNG=/path/out.png` on the app binary renders the editor's detail pane to a PNG via
  `ImageRenderer` and exits (`Sources/TunaboatApp/RenderPreview.swift`). Development-only, gated by
  the environment variable.

`ImageRenderer` will not lay out `NavigationSplitView` or `ScrollView`, and draws interactive
controls as a placeholder glyph — hence `TunnelDetailView.content` being exposed separately from
its scrolling `body`. A render full of yellow "prohibited" symbols where the text fields belong is
that limitation, not a broken layout.

- `TUNABOAT_LAYOUT_PROBE=1` makes `LayoutProbe` report a view's measured size from the **live**
  window to stderr (run the binary directly, not via `open`, to capture it). This is the only
  faithful oracle for layout: a 16pt-tall options row is one line, a ~60pt one is three. Use it
  to settle any "does it actually lay out that way" question, because `ImageRenderer` does not.

Neither tool renders a live **menu**, and the menu behaves differently from the rest of the UI:
SwiftUI treats `Image(systemName:)` in a menu as a template image and tints it with the menu's own
colour, discarding `foregroundStyle`. Status colour in the menu therefore comes from a
non-template `NSImage` (`TunnelIndicator.menuDot()`), and anything the colour conveys is also
written in the row's text. Menu appearance can only be verified by opening it.

### Saving

Edits are written **only** by the editor's Save button (⌘S). Nothing auto-saves: a keystroke in a
port field would otherwise rewrite the file and restart a live tunnel on every character. Unsaved
state is shown in the editor toolbar and in the menu.

**Deleting is the exception, and is immediate**: it stops the tunnel and writes the removal at
once. A deletion is complete the moment it is made, and requiring a save to finish one left an ssh
process running for a tunnel that had already disappeared from every list. `ConfigStore.removeTunnel`
rewrites the file from what is *on disk* rather than from the in-memory list, so a deletion commits
only the deletion and leaves other in-flight edits unsaved.

Adding and duplicating still need a save — a new tunnel has no host yet, and writing an incomplete
entry to disk on every click would be worse than the friction. `isDirty` is derived by comparing
the in-memory specs against the last known on-disk state, so it cannot claim unsaved changes that
are already written.

## Launch at login

The app registers **itself** as a login item via `SMAppService.mainApp` (`LoginItem` in
`TunaboatCore`). No LaunchAgent plist is written by hand, and there is deliberately **no headless
daemon**: the app is the single owner of the ssh children, and an agent running `tunaboat` in the
background would fight it for every port it also binds. Per-tunnel "Connect at launch" then does
the rest. Registration appears in System Settings → General → Login Items, where the user can
revoke it — which is why the status is re-read on `NSApplication.didBecomeActiveNotification`
rather than trusted from launch.

Three things about `SMAppService` that are not guessable from the API:

- **`.notFound` means "never registered", not "the bundle is missing".** The name and Apple's
  documentation both suggest otherwise, and mapping it to an error state disables the control
  permanently on every fresh install. Measured against a real bundle it is what `mainApp.status`
  returns before the first registration — under ad-hoc *and* Developer ID signatures, inside and
  outside a build directory, launched directly and through LaunchServices — and `register()`
  succeeds from it. `LoginItemStatus` folds it in with `.notRegistered`.
- **`.requiresApproval` cannot be cleared by the app.** The user switched it off in System
  Settings and only they can switch it back; the menu offers
  `SMAppService.openSystemSettingsLoginItems()` instead of a checkbox that cannot work. It is
  shown *ticked*, because the app really is registered.
- **Registration is by path.** `LoginItemLocation` classifies the running bundle first:
  `swift run TunaboatApp` has no bundle at all and cannot register, and a bundle under `.build`
  or `DerivedData` registers fine but points launchd at a path the next clean deletes — a warning,
  not a refusal.

`TUNABOAT_LOGIN_PROBE=1` on the app binary prints the bundle path, location and status to stderr
and exits; `=roundtrip` additionally registers and immediately unregisters, to establish whether a
status can actually be acted on. Both are development-only. The round trip is self-cleaning, but
it is the one probe here with a real side effect, so do not leave it half-run.

**A probe is a front end too, and must take its ssh children with it.** Any probe that ends the
process early has to exit through `probeExit`, which calls `SSHProcessRegistry.terminateAll()`:
a bare `exit()` runs neither `applicationWillTerminate` nor the SIGTERM handler, and merely
constructing `AppModel` starts the auto-connect tunnels. Four orphaned ssh processes were
produced exactly this way, each still holding port 5901. To capture either
through a LaunchServices launch rather than a direct exec — which is a different environment, and
worth checking separately:

```sh
open -W --stderr /tmp/probe.txt --env TUNABOAT_LOGIN_PROBE=1 .build/Tunaboat.app
```

## Tunnel lifecycle

A tunnel spec maps to `ssh` flags: `-L` local forward, `-R` remote forward, `-D` SOCKS proxy.
Every spawn carries:

- `-N -T` — no remote command, no TTY
- `-v` — the verbose stderr is the only status channel there is
- `-o ServerAliveInterval=…` / `-o ServerAliveCountMax=…` — so a dropped network kills the process
  instead of hanging forever, which is what the supervisor's restart logic keys off
- `-o BatchMode=yes` for CLI/non-interactive paths, so a missing key fails fast instead of blocking
  on a password prompt with no terminal attached

**Not** `-o ExitOnForwardFailure=yes`, despite it looking obviously right. ssh merges forwards from
`~/.ssh/config` with the ones we pass and gives no way to separate them — `ClearAllForwardings=yes`
drops our own `-L` flags too (verified against OpenSSH 10.3p1). That option therefore lets a
config-file forward kill a tunnel over a port Tunaboat never configured, which is exactly what happens
on a host whose config carries a `RemoteForward` that is already bound. `TunnelStateMachine`
attributes forward failures by **port ownership** instead: a port this tunnel asked for is fatal,
a port it did not is a warning that leaves the tunnel up.

### Reading ssh's output

State is derived, not authoritative, and the derivation is subtler than it looks. Three rules, each
learned from real OpenSSH 10.3p1 output (`claude-debug/ssh-output-strings.md`):

- `Local forwarding listening on … port N.` is printed **before** the bind is attempted, and is
  **not** retracted when the bind fails. It is a claim, not a confirmation.
- `bind [addr]:N: …` is per-address-family. ssh tries `::1` and `127.0.0.1` separately; one failing
  while the other succeeds still leaves a working forward. Not a verdict either.
- `channel_setup_fwd_listener_tcpip: cannot listen to port: N` **is** the verdict.

And `Entering interactive session.` means the *session* is up, not the forwards — ssh prints it
even when every forward failed. Reaching `.connected` requires the session line *and* every
requested forward confirmed. Anything less is the "looks healthy, carries nothing" state.

Since ssh is not told to exit on forward failure, the supervisor must terminate the process itself
when a forward it owns fails.

**Every front end must take its ssh children with it.** A child that outlives its parent is
re-parented to launchd and goes on holding every forwarded port, so a later run fails to bind a
port that nothing visible is using — and the failure looks like a bug in whatever ran next. The
CLI handles SIGINT/SIGTERM; the app uses `SSHProcessRegistry.terminateAll()` from both
`applicationWillTerminate` and its own SIGTERM handler, since the former does not run for a bare
`kill`. `SSHProcessRegistry.livePIDs` is the way to check for leaks;
`claude-debug/orphan-check.sh` is the regression script.

A finished run must also release `TunnelSupervisor.supervision`, or the completed task blocks
every later `start()` and a failed tunnel can never be retried.

Prefer passing a user's `Host` alias straight through to `ssh` rather than decomposing it into
user/host/port — the alias may resolve to config the app never sees.

## Config

User tunnel definitions live in a file the user can hand-edit and diff, read by both front ends
(`~/.config/tunaboat/tunnels.json` preferred over `~/Library/Application Support` for exactly that
reason). The CLI and the app must not each keep their own private notion of the tunnel list.

`ConfigStore` honours `XDG_CONFIG_HOME`, which is also how tests point it at a temporary directory
instead of the real configuration. The legacy `tmon` fallback applies **only** to the default
location: a caller that names an explicit file gets that file and no fallback.

Never write private keys, passphrases, or passwords into config, logs, or state files. Secrets stay
in the Keychain or the ssh-agent.

## Testing

Tests use **swift-testing** (`import Testing`, `@Test`/`@Suite`/`#expect`), not XCTest.

Unit-test spec→argv construction, config round-tripping, and supervisor state transitions without
touching the network. `SSHProcess`/`SSHLauncher` are `Sendable` protocols precisely so supervisor
tests can inject a scripted fake launcher instead of spawning a real ssh — `SystemSSHLauncher` is
only one implementation. For anything that needs a real endpoint, an `ssh -L … localhost` loopback
tunnel to a local listener works and needs no external host.

If a test fails, fix the code under test. Do not make a test pass by swapping in a different backend
or by stubbing out the thing the test exists to check — a bug is still a bug.

## Conventions

- Scratch scripts, probe data, and one-off fixtures go in `claude-debug/`, with unique names.
  `.md` notes there are committed; code and data files there are not, and nothing there is deleted.
- Commits and commit messages only when explicitly asked.
- `AI.md` tracks AI vs. human contribution — update it alongside any commit message.
