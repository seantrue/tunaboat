# AI.md — contribution accounting for Tunaboat

*About AI slop.*

Yes, much of what follows was written by a machine, and "slop" is a fair label to keep handy. Think
of it as instant ramen: quick, salty, genuinely useful at 2am, and nobody should pretend it came off
a stove after an afternoon of work. The honest answer to "how much of this is real cooking?" isn't a
disclaimer at the top — it's the accounting below, which names what the AI wrote, what the human
wrote, and what the AI got wrong that testing had to catch. Read it before you trust the packaging.
Bon appétit, but mind the sodium content.

**Purpose:** track the split between AI-assisted and human-authored work in this repository —
lines of code, functionality, research, and documentation — so the provenance of any part of Tunaboat
can be traced.

## Roles

- **Human maintainer:** Sean True — project intent, architecture decisions, review, and final say
  on anything shipped.
- **AI assistant:** Claude Code (Opus 5) — drafting, scaffolding, and documentation under direction.

## Ledger

| Date | Author | Item | Notes |
|---|---|---|---|
| 2026-09-07 | Human | Project definition | Named the project, chose macOS/Swift, and decided the three shaping questions: menu bar **+** CLI, SwiftPM, spawn `/usr/bin/ssh`. |
| 2026-09-07 | AI | `CLAUDE.md` | Drafted from the human's answers plus a toolchain probe (Swift 6.3 / Xcode 26.6). Includes the `ExitOnForwardFailure` / `ServerAliveInterval` / `BatchMode` rationale and the "state is derived, not authoritative" rule. |
| 2026-09-07 | AI | `AI.md` | This file. |
| 2026-09-07 | Human | Direction | Approved scaffolding; asked for an analysis of the installed tynsoe SSH Tunnel Manager and a proposed implementation + UI, with credit for reading an existing STM config. |
| 2026-09-07 | AI | Reverse-engineering of STM 2.2.7 | Recovered the preferences schema from the live plist and the app binary (`strings`, `Localizable.strings`, scriptTerminology, Authenticator headers). |
| 2026-09-07 | AI | SPM scaffold | `Package.swift`, three targets, swift-argument-parser dependency. |
| 2026-09-07 | AI | `TunaboatCore` | `TunnelSpec`/`Forward` model, `SSHCommand` argv builder, `ConfigStore`, `STMImporter`. |
| 2026-09-07 | AI | `tunaboat` CLI | `list`, `show`, `import` (with `--dry-run`). |
| 2026-09-07 | AI | `TunaboatApp` | MenuBarExtra skeleton; supervisor wiring still a TODO. |
| 2026-09-07 | AI | Tests | 16 tests across argv construction and STM import, all passing. |
| 2026-09-07 | Human | Direction | "Go ahead" — build the supervisor. |
| 2026-09-07 | AI | ssh output vocabulary | Verified every parser pattern against OpenSSH 10.3p1 on this machine: live captures plus format strings read out of `/usr/bin/ssh`. Recorded in `claude-debug/ssh-output-strings.md`. |
| 2026-09-07 | AI | `SSHEvent` / `SSHOutputParser` | Classifies `ssh -v` stderr into 11 event kinds. Pure. |
| 2026-09-07 | AI | `TunnelState` / `TunnelStateMachine` | Six-state ladder modelled on STM's, plus classified failures with a `isRetryable` distinction STM lacks. Pure value type. |
| 2026-09-07 | AI | `SSHProcess` / `SystemSSHProcess` | Actor-based process abstraction so supervision is testable without spawning ssh. |
| 2026-09-07 | AI | `TunnelSupervisor` / `RetryPolicy` | Actor owning one ssh process; exponential capped backoff, retrying only retryable failures. |
| 2026-09-07 | AI | `tunaboat up` | Foreground run with live status. |
| 2026-09-07 | AI | Menu bar UI | `TunnelListModel` / `TunnelRow` (`@Observable`), per-tunnel colour + inline failure reason, aggregate status icon. |
| 2026-09-07 | AI | Tests | 44 total, all passing, including supervisor retry behaviour driven by a scripted fake launcher. |
| 2026-09-07 | Human | Access + domain knowledge | Confirmed passwordless login to `backend` and named the services running on it (cockpit, rabbitmq, …), which made live validation possible and turned four latent design bugs into observed ones. |
| 2026-09-07 | AI | Forward-failure attribution | Replaced `ExitOnForwardFailure=yes` with per-port ownership: a failing forward inherited from `~/.ssh/config` is a warning, one Tunaboat requested is fatal. Added `TunnelStatus` to carry warnings alongside state. |
| 2026-09-07 | AI | Corrected output model | Claim/verdict handling for listening lines, per-family bind tolerance, and `.connected` gated on every requested forward. |
| 2026-09-07 | AI | Signal handling | `tunaboat up` terminates its ssh child on SIGINT/SIGTERM. |
| 2026-09-07 | AI | Live validation harness | `claude-debug/bind-port.py`, `claude-debug/live-foreign-forward-test.sh`. |
| 2026-09-07 | AI | Tests | 61 total, all passing. |
| 2026-09-07 | Human | Direction | "Go for GUI". |
| 2026-09-07 | AI | `PortConflicts` | Detects local ports claimed twice; `-R` listen ports correctly excluded since they bind on the server. |
| 2026-09-07 | AI | `AppModel` / `TunnelRow` | Shared observable state for menu and editor, with row reconciliation so saving an unrelated edit does not tear down a live tunnel. |
| 2026-09-07 | AI | Editor window | `NavigationSplitView`, editable forward rows, conflict highlighting, import/runtime notes, and a live `$ /usr/bin/ssh …` preview with copy — the affordance STM lacks. |
| 2026-09-07 | AI | Menu bar | Per-tunnel colour and inline failure reason, warnings shown without turning the tunnel red, worst-state-wins icon, first-run editor. |
| 2026-09-07 | AI | `Scripts/bundle-app.sh` | Assembles an ad-hoc-signed `Tunaboat.app` with `LSUIElement`. |
| 2026-09-07 | AI | GUI verification tooling | `claude-debug/list-app-windows.swift` and the `TUNABOAT_RENDER_PNG` render mode, so UI claims are checked rather than assumed. |
| 2026-09-07 | AI | Tests | 71 total, all passing. |
| 2026-09-07 | Human | Bug report | Found by using the app: deleting a tunnel removed it from the configuration but left it in the sidebar. |
| 2026-09-07 | AI | `TunnelListPresenter` | Moved list presentation into `TunaboatCore` so it is testable, and fixed the reported bug at its root: the list is now derived from the specs being edited, never from the live supervisors. |
| 2026-09-07 | AI | Delete/save lifecycle | Deleting stops the tunnel immediately rather than leaving an invisible ssh; saving an edit to a running tunnel reconnects it instead of silently leaving it down. |
| 2026-09-07 | AI | Tests | 78 total, all passing. |
| 2026-09-07 | Human | Design direction | Specified the indicator colours: green connected, red error, yellow idle. |
| 2026-09-07 | AI | Indicator recolour | Applied the specified mapping; moved the connected-with-warning case to green with a separate ⚠︎ badge (yellow now means idle), kept orange for transient states, and routed the editor and menu through one colour mapping so they cannot drift. |
| 2026-09-07 | AI | `claude-debug/render-indicator-swatches.swift` | Renders the colour mapping to a PNG so it can be checked visually. |
| 2026-09-07 | AI | Tests | 79 total, all passing. |
| 2026-09-08 | Human | Bug report + question | The dropdown showed no connection state on first open; asked when the configuration is saved. |
| 2026-09-08 | AI | Menu state display | Every row now leads with its state ("Idle · 7 forwards"), and the menu dot is drawn as a non-template `NSImage` because SwiftUI tints menu icons as templates and was discarding the colour entirely. |
| 2026-09-08 | AI | Save discoverability | ⌘S, an "Unsaved changes" toolbar indicator, and a "Save Configuration" menu item shown only while dirty. Saving stays explicit by design. |
| 2026-09-08 | AI | Tests | 80 total, all passing. |
| 2026-09-08 | Human | Design direction | Deleting a tunnel should not require a save. |
| 2026-09-08 | AI | Immediate deletion | `ConfigStore.removeTunnel` persists a deletion on its own, rewriting from disk so other unsaved edits are not committed as a side effect. `isDirty` is now derived from a comparison with the saved state rather than set by hand. |
| 2026-09-08 | AI | Tests | 86 total, all passing — six covering the store, which previously had none. |
| 2026-09-08 | Human | Bug report | Clicking a tunnel twice left it stuck on "Port 5901: Address already in use" with no way to clear the error. Screenshot supplied. |
| 2026-09-08 | AI | Restart after failure | `TunnelSupervisor.start()` was permanently blocked by the completed run task; the run loop now releases it, so a failed tunnel can be started again. |
| 2026-09-08 | AI | `SSHProcessRegistry` | The app now takes its ssh children with it on quit or SIGTERM, instead of orphaning them to launchd where they went on holding forwarded ports. |
| 2026-09-08 | AI | Auto-connect wiring | "Connect at launch" was inert — `startAutoConnectTunnels()` existed but was never called. |
| 2026-09-08 | AI | Tests | 88 total, all passing. |
| 2026-09-08 | Human | UI direction | Annotated screenshot: options side by side, notes as hover text on an info icon, command section collapsed by default. |
| 2026-09-08 | Human | UI direction | Shorten the destination host field; options still appearing stacked. |
| 2026-09-08 | AI | `LayoutProbe` | Reports a view's measured size from the live window, since `ImageRenderer` had already proved an unfaithful oracle. Measured the options row at 554x16 — one line — settling the question with evidence rather than argument. |
| 2026-09-08 | AI | Layout hardening | `fixedSize()` on each option toggle so a narrow pane can never wrap the labels into stacked columns; destination host field 130 → 92pt. |
| 2026-09-08 | Human | Correction | "Still not right" — the shortening was wanted on the connection Host field, not the forward destination field. |
| 2026-09-08 | Human | UI direction | Options panel should sit to the right of the Connection panel. |
| 2026-09-08 | AI | Two-column top section | Connection and Options side by side, options adapting between a row and a column via `ViewThatFits` depending on the space beside the fields. |
| 2026-09-08 | Human | Rename | Renamed the project to Tunaboat, full scope: app, CLI, modules, bundle id and configuration path. |
| 2026-09-08 | AI | Rename | `git mv` of every target, `Package.swift`, identifiers, UI strings, bundle script (`Tunaboat.app`, `dev.impressionist.tunaboat`), docs. `ConfigStore` gained a legacy-path fallback so an existing `~/.config/tmon/tunnels.json` is still read; five tests cover the migration. |
| 2026-09-08 | Human | Signing | Pointed at the sibling `pursuit` project for developer credentials and asked for a signed .app. |
| 2026-09-08 | AI | Investigation | Read pursuit's `apple/make-mac-app.sh` and export options, and inspected its shipped `Pursuit.app`: Developer ID Application (78DGVG7MYU), hardened runtime, secure timestamp, notarised. No secrets are kept in that repo; the identity lives in the keychain. |
| 2026-09-08 | AI | Signing support | `Scripts/bundle-app.sh --sign` / `--notarize`: Developer ID signing with hardened runtime and timestamp, inner binaries signed before the bundle, notarytool submit/staple/verify, and a clear error when the keychain profile is missing. Signature verified to match pursuit's shipped app. |
| 2026-09-08 | Human | UI direction | Notes hover not working, move the icon next to Host; move the Command section above the variable-height forwards list. |
| 2026-09-08 | AI | Note icon | Given a real hit area and a click-to-open popover, so a note stays readable even when the tooltip does not appear; relocated beside the Host field. |
| 2026-09-08 | AI | Section order | Command moved above Forwards, so the list's changing height no longer shifts everything beneath it. |
| 2026-09-08 | AI | `CLAUDE.md` accuracy | Removed the stale "greenfield / repo is empty / not a git repo yet" status, which the code had contradicted for several turns. |
| 2026-09-08 | AI | Auto-connect placement | Moved "connect at launch" off the menu bar label's `onAppear` and into `reload()`, so it does not depend on a view lifecycle event. Note the move was made on a mistaken diagnosis — see the defect note. |
| 2026-09-08 | AI | Form sizing | Connection fields sized to their content (220pt) instead of stretching to the pane edge, port 90 → 70pt, and the remove button moved back beside its forward row instead of being stranded at the far right. |
| 2026-09-08 | AI | Editor refinements | Options laid out horizontally with the long explanations moved to hover help; notes reduced to icons carrying their text on hover (and as accessibility labels); command preview collapsed by default with Copy still reachable while collapsed. |
| 2026-09-08 | Human | Direction | `init` — audit `CLAUDE.md` against the code; then commit. |
| 2026-09-08 | AI | `CLAUDE.md` audit | Checked every claim against the source rather than re-reading the prose. Corrected three that had drifted (signing described as unbuilt though `--sign`/`--notarize` ship; `Sources/Tunaboat/` for the lowercase `Sources/tunaboat/`; `~/.config/Tunaboat/` for `~/.config/tunaboat/`), and added the manifest's real floor (`swift-tools-version: 6.0`, `.macOS(.v14)`), the CLI subcommands, `XDG_CONFIG_HOME` and the limits of the `tmon` fallback, swift-testing over XCTest, and the `SSHProcess`/`SSHLauncher` injection seam. |
| 2026-09-08 | AI | Stale-build note | Recorded the `ModuleCache` failure left by the directory rename, since it reads as a source error and is not one. |
| 2026-09-08 | Human | Commit | Asked for the initial commit. |
| 2026-09-08 | Human | Direction | "Now do the LaunchAgent for login-at-launch." |
| 2026-09-08 | Human | Decision | Chose registering the app itself (`SMAppService.mainApp`) over a headless LaunchAgent running the CLI, when asked which of the two "LaunchAgent" meant. The alternative would have needed a daemon mode and an arbitration story for who owns a forwarded port when app and daemon both run. |
| 2026-09-08 | AI | `LoginItem` | `LoginItemStatus`, `LoginItemLocation`, and a `LoginItemBackend` protocol so the toggle logic is testable without registering anything on the developer's machine. `SystemLoginItemBackend` is the only part that touches `SMAppService`. |
| 2026-09-08 | AI | Menu control | "Launch at Login" toggle, replaced by an "Open Settings…" button in the `requiresApproval` state the app cannot clear itself; status re-read on app activation so a revocation made in System Settings is noticed. |
| 2026-09-08 | AI | `TUNABOAT_LOGIN_PROBE` | Reports location and status from inside a real bundle, with a self-cleaning `roundtrip` mode that registers and immediately unregisters. Written because the unit tests cannot reach `Bundle.main`, and it is what caught the defect below. |
| 2026-09-08 | AI | Tests | 108 total, all passing — 15 covering login item location, toggle semantics, and the `SMAppService` status mapping. |
| 2026-09-08 | Human | Direction | "Build and install a signed copy." |
| 2026-09-08 | AI | Orphan fix | Routed every development probe's early exit through `probeExit`, which terminates the ssh children first. Found while preparing the install, not by a test. |
| 2026-09-08 | AI | Install | Developer ID signed build installed to `/Applications`, verified to launch, and confirmed to report `location: installed` / `status: disabled` — the state in which the toggle is actionable and carries no caveat. |
| 2026-09-08 | Human | Direction | "Notarize it and build a .img for distribution, including a drag to Applications target." |
| 2026-09-08 | AI | Notarisation | App submitted to Apple, accepted, stapled, and verified as `source=Notarized Developer ID`. |
| 2026-09-08 | AI | `Scripts/make-dmg.sh` | Builds a signed, notarised, stapled disk image with an `/Applications` symlink as the drag target; Finder window layout applied by AppleScript against a mounted read/write image, and treated as never fatal since it needs an Automation permission the build machine may refuse. |
| 2026-09-08 | AI | Version fix | `CFBundleShortVersionString` was coming out as a git hash; separated the marketing version (from a `v[0-9]*` tag, falling back to `0.1.0`) from `CFBundleVersion` (commit count). |
| 2026-09-08 | Human | Release | Asked for a `v0.1.0` tag, anchoring the version to something real rather than to the script's fallback. |
| 2026-09-08 | Human | Publication | Asked for a private GitHub repository, pushed tags, and the disk image attached to a release. |
| 2026-09-08 | AI | Publication | `seantrue/tunaboat` (private), `main` and `v0.1.0` pushed, `Tunaboat-0.1.0.dmg` attached to the v0.1.0 release. |
| 2026-09-08 | Human | Direction | Scrub the real host names from checked-in code, data and docs, using `backend` and `appserver` as examples. |
| 2026-09-08 | AI | Scrub | Replaced the two real host names with `backend` and `appserver` throughout, along with the LAN addresses and FQDN captured in the live ssh output, which identified the same hosts just as directly. Documentation-range addresses (RFC 5737) used for the substitutes. The captures themselves are unchanged and still real. The first attempt left the old names sitting in this very row — the scrub has to cover the note describing it. |
| 2026-09-08 | Human | Direction | Asked for a `README.md` written for the end user, with developer documentation kept out of it and left in `CLAUDE.md`. |
| 2026-09-08 | AI | `README.md` | Install, first tunnel, status colours, options, launch at login, import, CLI, the configuration file, and troubleshooting. The example config and the `tunaboat show` output in it were run rather than composed; two claims written from memory were wrong and corrected against the binary — the build is arm64 only, and the import-note icon opens on click, not hover. |
| 2026-09-08 | Human | Direction | Add an x86_64 build, cut a new version for it, and squash the history to leave the personal details out. |
| 2026-09-08 | AI | Universal build | `--universal` on `bundle-app.sh` (arm64 + x86_64), with the arch flags also passed to `--show-bin-path` — without that a universal build's output directory is missed and stale single-arch binaries get signed instead. The script now reports `lipo -archs` and fails if the flag did not take effect; `make-dmg.sh` builds universal by default and warns when packaging an arm64-only app. |
| 2026-09-08 | AI | Scrub, second pass | Username and home directory removed from the test fixtures and the ssh output notes. The signing identity is deliberately kept: it is required to build and is embedded in every signed binary already. |
| 2026-09-08 | AI | History | Squashed to a single commit, so the earlier host names and username are not recoverable from the repository. `v0.1.0` withdrawn — its commit no longer exists, and its disk image was Apple-silicon only. |
| 2026-09-08 | Human | Artwork | Supplied `tunaboat.png`/`.svg` — a boat trolling many lines out to many fish — and asked where it should go, floating a watermark behind the editor. |
| 2026-09-08 | AI | Recommendation | Advised against the watermark (dense form, dark mode, uneven control backgrounds) and pointed at the real gap: the app had no icon at all. |
| 2026-09-08 | Human | Decision | Chose the app icon, the editor's empty pane, and the disk image backdrop; dropped the watermark. |
| 2026-09-08 | AI | `Scripts/make-assets.py` | Derives the `.icns`, the in-app template mark and the disk image backdrop from the source art. Outputs committed, so a normal build needs neither Pillow nor the artwork. |
| 2026-09-08 | AI | Icon wiring | `CFBundleIconFile` plus the copy of SwiftPM's resource bundle into `Contents/Resources`, without which `Bundle.module` would crash the packaged app. |
| 2026-09-08 | AI | Disk image backdrop | Multi-resolution TIFF via `tiffutil`, staged into `.background/`, with the mount/detach handling hardened after a stale mount blocked a build. |
| 2026-09-08 | Human | Art direction | Measured the backdrop against the real window: wordmark ~40pt too low, mark ~15pt too low. |
| 2026-09-08 | AI | Backdrop placement | Applied both offsets and moved vertical placement from fractions to window points, the unit the corrections arrive in. Raising the mark required narrowing it — at its old size, centring it that high pushed the bow off the top edge, which it had been clipping slightly all along. |
| 2026-09-08 | Human | Direction | Bump the release, commit, build, upload the disk image — and add a formatted version of the documentation. |
| 2026-09-08 | AI | `Scripts/make-docs.sh` | `README.md` to a single self-contained `docs/Tunaboat.html` via pandoc, stylesheet inlined and artwork embedded, shipped as a release asset beside the disk image. |

## Code

| Metric | AI | Human |
|---|---|---|
| Swift LOC (`Sources/`) | 2834 | 0 |
| Test LOC (`Tests/`) | 1719 | 0 |
| `Package.swift` + scripts + stylesheet | 856 | 0 |
| Docs (lines, incl. this file) | 1106 | 0 |
| Artwork | 0 | 1 source drawing |
| Tests passing | 108 in 19 suites | — |

Counted with `wc -l` at the initial commit; earlier rows in this table were estimates and ran low.

The human's contribution so far is not in lines: the three shaping decisions (menu bar + CLI,
SwiftPM, spawn `/usr/bin/ssh`) determined essentially all of the above, and the existing STM
configuration the importer was validated against is the human's real working setup.

## Defects in AI-written code found by testing

This section is not decorative. Recorded so far:

- **Swift 6 data race in AI-written test code.** The AI declared the import fixture as
  `static let ... : [String: Any]`, which the compiler rejected: `[String: Any]` is not `Sendable`,
  so a shared static is a data race. Caught by `swift test` failing to build, not by review. Fixed
  by making it a function rather than a stored global — deliberately *not* by adding
  `nonisolated(unsafe)`, which would have silenced the diagnostic without removing the sharing.
- **Missing parser branch for the one signal that matters most.** `SSHEvent` declared
  `.interactiveSessionEntered` — `Entering interactive session.`, the line STM itself keys off —
  and `TunnelStateMachine` handled it, but `SSHOutputParser` had no branch that ever produced it.
  A tunnel with only `-R` forwards (i.e. the `appserver` connection in the real config) would have
  sat at "Authenticated" forever and never reported itself up. Caught by a parser unit test, not
  by review; the supervisor test passed regardless because its fixture also had a local forward.
- **Async subcommand under a synchronous root.** `tunaboat up` was declared `AsyncParsableCommand`
  beneath a `ParsableCommand` root, so its `run()` was never called. Invisible to `swift build`
  and to every unit test; caught only by running the command end to end, where ArgumentParser
  printed the diagnostic itself.
- **Spurious repeated states published to observers.** The supervisor published on every parsed
  event, including ones that only record a failure cause without changing state, so the CLI
  printed `Connecting…` twice and the menu would have flickered. Caught by reading real
  end-to-end output, then pinned with a regression test.
- **`ExitOnForwardFailure=yes` was wrong, and the AI put it in `CLAUDE.md` as a rule.** It was
  presented as obviously correct in the first design write-up and enshrined as project guidance
  before any code ran. Against the real `backend` host it killed the connection outright,
  because `~/.ssh/config` carries `RemoteForward 9998` for that host and ssh merges config
  forwards with ours. Found only by connecting to a real host the human granted access to.
  `ClearAllForwardings=yes` was tried as a fix and also proved wrong — it clears the
  command-line `-L` flags too. Replaced with port-ownership attribution; `CLAUDE.md` corrected.
- **Counting "Local forwarding listening" lines as established forwards.** ssh prints that line
  *before* attempting the bind and does not retract it on failure, so the AI's status ladder
  counted forwards that had failed. This is precisely the "state is derived, not authoritative"
  trap the AI itself had written into `CLAUDE.md` one session earlier.
- **Reporting `Connected` for a session whose every forward was dead.** `Entering interactive
  session.` was treated as meaning the tunnel was up; ssh prints it even when all forwards
  failed. Observed live: Tunaboat printed `Connected` and then immediately `Port 19090: Address
  already in use`. Now `.connected` requires the session line *and* every requested forward.
- **Orphaned ssh children.** Killing `tunaboat up` left its ssh process running and holding every
  forwarded port; a stale orphan then silently poisoned two subsequent test runs with bogus
  "port in use" results before being noticed. Fixed with SIGINT/SIGTERM handlers.
- **A failed tunnel could never be restarted.** `start()` guarded on `supervision == nil`, but
  only `stop()` ever cleared it — so once a run ended on a terminal failure, the completed task
  sat in that slot and every later Start silently did nothing. The user hit it immediately:
  a failed tunnel stuck on its error with no way to clear it. None of the AI's supervisor tests
  had ever called `start()` a second time.
- **The app orphaned its ssh children.** The equivalent bug was found and fixed for the CLI two
  turns earlier, and the AI did not carry the fix across to the GUI. Killed app instances left
  ssh processes re-parented to launchd, still holding port 5901 — which is what the user's
  "Address already in use" actually was, caused by the AI's own testing rather than by anything
  they did. Fixed with `SSHProcessRegistry` plus `applicationWillTerminate` and SIGTERM handling.
- **"Connect at launch" did nothing.** `startAutoConnectTunnels()` was written but never called,
  so the checkbox had no effect for four turns. Shipped-looking UI with no behaviour behind it.
- **Case-insensitive filesystem collision in the app bundle.** The signing rewrite placed the CLI
  at `Contents/MacOS/tunaboat` alongside the app binary `Contents/MacOS/Tunaboat`. On macOS's
  case-insensitive filesystem those are one file, so the CLI overwrote the app: the signed bundle
  launched and printed CLI help instead of showing a menu bar item. Everything reported success —
  the build, the signature, the verification — because the bundle was internally consistent, just
  wrong. Caught only by launching it and finding no process. The CLI now lives in
  `Contents/Helpers/`.
- **A scripted rename silently did nothing, twice over.** A `sed` using `\btmon\b` was run
  across every source file; BSD `sed` does not support `\b`, so it matched nothing and reported
  success. The rename looked done until a grep showed the UI still said "tmon". The same class of
  silent no-op had already happened once this session with an indentation-mismatched replacement.
  Scripted edits fail quietly and must be verified by grepping for what should no longer be there.
- **The rename then over-applied.** Redone with a real word boundary, it rewrote the legacy
  `~/.config/tmon` paths inside the migration tests — the one place the old name is load-bearing.
  Caught by the test suite.
- **Misdiagnosed a failing tunnel as a failing feature.** Seeing no ssh process after launch, the
  AI concluded "connect at launch" was firing unreliably and rewired it, before checking what the
  tunnel actually did. Running the same spec through the CLI showed auto-connect worked fine: the
  tunnel connected and was then killed because its `-R 9998` duplicates a `RemoteForward` that
  `~/.ssh/config` already supplies for that host, so the server refused the second request and,
  the forward being Tunaboat-owned, the failure was fatal. The rewiring is still the better place for
  it, but it was done for the wrong reason.
- **Two layout regressions introduced while making Options sit beside Connection**, both caught
  by rendering before the user saw them: the `HStack` compressed the connection `Grid` until its
  "Name"/"Host" labels wrapped to one letter per line, and then `fixedSize()` applied to *both*
  columns removed the width constraint so `ViewThatFits` always chose the wide row and pushed the
  pane past its edge. Only the connection column may be fixed.
- **A scripted edit silently did nothing.** The reordering of the detail sections was applied with
  a text replacement whose indentation did not match the file, so the build succeeded and the
  layout was unchanged. Caught only because the render still showed the old order — a reminder
  that these edits fail silently and need verifying, not assuming.
- **Misread which field to shorten.** "Make the hostfield shorter" was applied to the forward
  destination host rather than the connection Host field the screenshot showed spanning the whole
  pane. Two of the user's turns were spent on one refinement. The wider fault was reaching for a
  narrow reading of an ambiguous instruction while a screenshot showing the actual problem was in
  hand.
- **Reported a render as verification when it could not verify.** The AI cited an `ImageRenderer`
  output as proof the options were laid out side by side, having already documented that the same
  renderer cannot lay out `ScrollView` or `NavigationSplitView` at all. It happened to be right;
  it was not evidence. `LayoutProbe`, which measures the live window, now exists for this.
- **A test helper written by the AI swallowed its own errors.** `withTemporaryStore` was first
  written with `try?`, which would have silently hidden any assertion that threw. Caught by the
  compiler complaining about an unrelated `rethrows` mismatch, not by review.
- **The menu bar dropdown showed no connection state — two independent causes, both found by
  the human using the app.** An idle tunnel's row displayed only its forward count, so nothing
  stated the connection state until something was started; and the coloured status dot was an
  `Image(systemName:)`, which SwiftUI renders inside a menu as a *template* image tinted by the
  menu, discarding `foregroundStyle` entirely. The rendered-PNG checks the AI had been relying
  on could not have caught either: neither renders a live menu.
- **Deleted tunnels stayed in the sidebar — found by the human, using the app.** The list was
  built from the live supervisors, which are rebuilt only on save, so a deleted tunnel lingered
  and a newly added one would not have appeared at all. Three places had the same defect (the
  sidebar, the menu, and the empty-state check). This is precisely the untested-GUI gap recorded
  below, and the AI had flagged that gap without acting on it. Fixed by moving list presentation
  into `TunaboatCore` as `TunnelListPresenter` and covering it with 7 tests, so the list can no
  longer be derived from the wrong collection without a test failing.
- **The icon was designed by reasoning and came out wrong three times.** Each attempt looked
  correct in the code and failed the moment it was rendered and inspected: a linear
  darkness-to-alpha map turned the source's uneven paper into a ghost rectangle behind the boat;
  downsampling hairline strokes deleted them, giving an icon that was very nearly blank at every
  size; and fitting the small-size crop by width alone drove a tall mark straight off the plate.
  A fourth assumption — that the boat alone would read better than the full mark at 16pt — was
  also wrong, and only a side-by-side render showed it. Nothing here was catchable by testing;
  it needed looking at the output.
- **A cleanup loop detached every disk image on the machine.** Trying to clear one stuck
  `/Volumes/Tunaboat`, the AI iterated over the whole of `hdiutil info` instead of filtering to
  the project's own images, and detached Xcode simulator runtimes and a Time Machine
  sparsebundle along with it. No backup was running and the simulator volumes remount on demand,
  so nothing was lost — but the blast radius was the user's whole machine, for a build-script
  problem, and the loop did not even detach the volume it was aimed at. `make-dmg.sh` now keeps
  the device from its own `hdiutil attach` and detaches only that.
- **The first release was Apple-silicon only, and nothing said so.** `swift build` targets the
  building machine, so the notarized `v0.1.0` disk image could not launch on an Intel Mac at all —
  not a degraded experience, an absent architecture with no Rosetta fallback. Every check the AI
  ran passed: it built, signed, notarized, stapled, mounted, installed and launched, because all of
  that happened on the machine that built it. The gap only surfaced when the README needed a
  "Requirements" line and the AI checked `lipo -archs` rather than writing what it assumed. The
  build now fails if `--universal` was asked for and did not take.
- **The first commit silently changed the app's version to a git hash.** `bundle-app.sh` set
  `CFBundleShortVersionString` from `git describe --tags --always`, which the AI wrote and
  verified while the repository had neither tags nor commits — so the `|| echo 0.1.0` fallback
  fired and the plist read `0.1.0`, exactly as intended. The moment a commit existed the command
  succeeded instead, and the shipping app began reporting its version as `30069bc`. The defect
  was introduced by a change made two turns earlier in a *different* file, and was invisible
  until a distribution artifact was named after it. Marketing version and build number are now
  derived separately, from a tag and a commit count.
- **The AI's own probe orphaned four ssh processes — the exact bug this file already records
  twice.** `TUNABOAT_LOGIN_PROBE` ended with `exit(0)`, which runs neither
  `applicationWillTerminate` nor the SIGTERM handler, and simply constructing `AppModel` starts
  the auto-connect tunnels. Each probe launch therefore left an ssh holding port 5901,
  re-parented to launchd. Four had accumulated before a `ps` run for an unrelated reason showed
  them. `RenderPreview` had carried the same latent defect since it was written. The AI had
  written the rule ("every front end must take its ssh children with it"), fixed the bug twice
  in the CLI and the app, documented the orphan-check script — and then reintroduced it in new
  code, because "a probe" did not register as "a front end". Both now exit through `probeExit`.
- **`SMAppService.notFound` mapped to an error, which would have disabled Launch at Login on
  every fresh install.** The status is named `notFound` and Apple documents it as the service
  not being found, so the AI mapped it to "unavailable — cannot be managed", making the toggle
  permanently unclickable. It is in fact what `mainApp.status` returns before the app has *ever*
  been registered: measured against a real bundle under ad-hoc and Developer ID signatures,
  inside and outside a build directory, and launched both directly and through LaunchServices,
  it was `notFound` every time, and `register()` succeeded from that state and moved it to
  `enabled`. Every unit test passed throughout, because they all drove a fake backend whose
  statuses the AI had chosen; the real API was never asked. Caught only by building the bundle
  and probing it, then by a register/unregister round trip. This is the same shape as
  "Connect at launch did nothing" above: a control that looks shipped and does nothing.
- **`CLAUDE.md` drifted from the code and said so with confidence.** By the time it was audited
  it claimed Developer ID signing was still to do — two sessions after the AI itself had written
  `--sign` and `--notarize` and verified the signature — and gave two paths (`Sources/Tunaboat/`,
  `~/.config/Tunaboat/`) with the wrong case, in a project whose own guidance warns that the
  filesystem is case-insensitive. The file carries the rule "when code contradicts this file, the
  code wins — update this file in the same change"; the AI wrote that rule and then did not follow
  it. Nothing catches this but reading the source and re-checking each claim, which is what the
  audit did.
- **The GUI is the least-tested part of the project, and that is a real gap.** `swift test`
  cannot reach the `TunaboatApp` target at all, so `AppModel`'s row reconciliation, the editor
  bindings, and every menu interaction are covered only by "it compiles" plus a rendered PNG.
  Logic was moved into `TunaboatCore` where it could be (naming, port conflicts); what remains in the
  app is untested — as the delete bug above demonstrated. More has since moved into `TunaboatCore`
  (list presentation, naming, port conflicts), but the SwiftUI bindings and menu interactions
  remain covered only by "it compiles". No one has yet clicked Start in the editor and watched a
  tunnel come up.
- **Untested claim, now flagged rather than asserted:** the remote-forward (`-R`) mapping is
  derived from a single real example (`appserver`, 4713→4713, symmetric ports) plus STM's field
  naming. A remote forward with *asymmetric* ports would distinguish the two possible readings of
  `leftPort`/`rightPort` and has not been verified against the original app.
- **Resolved:** the happy path is now proven live against `backend` — three simultaneous
  forwards (cockpit, rabbitmq, VNC) reaching `Connected` with HTTP 200 responses through the
  tunnel, plus the port-collision and inherited-forward-warning paths driven end to end. The
  remaining unverified case is an asymmetric-port `-R` forward, per the note above.

## A note on the history

This repository is a single commit. The development sequence it replaced is not lost — the ledger
above *is* that record, and is the reason the squash cost little. The history was rewritten because
the early commits contained real host names, addresses and a username from the maintainer's own
network, which a scrub at the tip could not remove from the objects behind it.

## Maintenance

Update this file whenever a commit message is written, whenever asked, and as part of any release.
