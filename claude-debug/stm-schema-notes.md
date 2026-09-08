# tynsoe SSH Tunnel Manager 2.2.7 — recovered schema

Source: `~/Library/Preferences/org.tynsoe.sshtunnelmanager.plist` on this machine, plus
selector/string extraction from `/Applications/SSH Tunnel Manager.app/Contents/MacOS/SSH Tunnel Manager`.
Recorded so the importer can be maintained without re-deriving it.

## Root

`tunnels` → array of connection dicts. Other root keys are app state (`NSStatusItem Preferred
Position Item-0`, `NSWindow Frame tunnelsWindow`, `LASTPID`, `PIDs`, `showInMenu`,
`ShouldHideDockIcon`, `openPalette`) and Sparkle/DevMate updater keys. Only `tunnels` matters.

## Connection dict

| Key | Type | Meaning | Tunaboat mapping |
|---|---|---|---|
| `connName` | String | Display name | `name` (falls back to `connHost` when empty) |
| `connHost` | String | Hostname or `~/.ssh/config` alias | `host` |
| `connUser` | String | Login user, `""` = none | `user` (nil when empty) |
| `connPort` | Int | ssh port | `port`, dropped when 22 |
| `connRemote` | Bool | Bind forwards on all interfaces | `listenOnAllInterfaces` → `GatewayPorts=yes` |
| `autoConnect` | Bool | Connect at launch | `autoConnect` |
| `compression` | Bool | `-C` | `compression` |
| `connAuth` | Bool | Use STM's password Authenticator | warning only |
| `encryption` | String | Pinned cipher, e.g. `3des` | warning only |
| `ignoreKeyWarning` | Bool | `StrictHostKeyChecking=no` | warning only — **not** carried over |
| `dontAlertForFailedPorts` | Bool | Suppress bind-failure alert | not modeled |
| `openLinkOnConnect` | String | URL opened on connect | `openURLOnConnect` |
| `socks4` / `socks4port` | Bool / Int | SOCKS proxy | dynamic (`-D`) forward + warning |
| `v1` | Bool | SSH protocol 1 | warning only |
| `tunnels` | Array | Forwards, see below | `forwards` |

## Forward dict

| Key | Type | Meaning |
|---|---|---|
| `tunnelType` | Int | `0` = local (`-L`), `1` = remote (`-R`) |
| `leftPort` | Int | Listening port |
| `rightPort` | Int | Destination port |
| `host` | String | Destination host, as resolved by the far end |
| `listenIP` | String | Optional bind address; key absent means ssh default |

## Runtime behavior

- Spawns `/usr/bin/ssh` via `NSTask` (`setLaunchPath:` / `setArguments:`).
- Connection is considered up when ssh's verbose stderr prints **`Entering interactive session.`** —
  the same signal Tunaboat's supervisor should use.
- Auth prompts go through a bundled `Authenticator.app` driven over `SSH_ASKPASS`, invoked by the
  AppleScript command `authenticate` with `tunnelName`, `query`, and a `fifo` path to write the
  passphrase back on. It offers "store password", i.e. Keychain.
- States in `Localizable.strings`: Idle, Connecting…, Authenticated, `Port %@ forwarded`, Connected,
  Reconnecting… — a finer-grained ladder than a simple up/down.
- Binary contains `StrictHostKeyChecking=no`, used when `ignoreKeyWarning` is set.
- Alerts on ports it could not bind (`FAILED_PORT_MESSAGE`), and offers to switch loopback-only
  forwards to all interfaces (`LISTENING_LOCAL_MESSAGE`).
- Ships `.stm` document export/import (`org.tynsoe.sshtunnelmanager.tunnelfile`) and Duplicate.
- `LSUIElement = true` — menu bar only, dock icon optional via `ShouldHideDockIcon`.
