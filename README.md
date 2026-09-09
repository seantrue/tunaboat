# Tunaboat

<img src="Art/tunaboat.png" alt="" width="380">

An SSH tunnel manager for macOS. It keeps your port forwards in one place, shows you at a glance
whether each one is actually carrying traffic, and tells you *why* when one isn't.

Tunaboat runs your tunnels through the `ssh` already on your Mac, so everything in your
`~/.ssh/config` keeps working exactly as it does in Terminal — `Host` aliases, `ProxyJump`,
`IdentityFile`, your ssh-agent, passphrases stored in the Keychain, and `known_hosts`. There is no
separate place to re-enter any of it.

It comes as a menu bar app and a `tunaboat` command, sharing one configuration file.

## Requirements

macOS 14 or later. The released build is a universal binary, so it runs natively on both Apple
silicon and Intel Macs.

## Install

1. Download `Tunaboat-<version>.dmg` from the
   [Releases page](https://github.com/seantrue/tunaboat/releases).
2. Open it and drag **Tunaboat** to your Applications folder.
3. Launch it from Applications.

The app is signed and notarized by Apple, so it opens without a Gatekeeper warning.

Tunaboat lives in the menu bar and has no Dock icon. Look for the ⇄ arrows near your clock.

## Your first tunnel

On first launch, with nothing configured yet, the editor window opens by itself. You can reopen it
any time from the menu bar icon → **Edit Tunnels…** (or press ⌘,).

Click **+** to add a tunnel, then fill in:

| Field | What to put |
|---|---|
| **Name** | Whatever you want to call it. This is also how you refer to it from the command line. |
| **Host** | The host to connect to. **If you have a `Host` alias in `~/.ssh/config`, just use the alias** — Tunaboat passes it straight to `ssh`, so all the settings behind it apply. |
| **User** | Leave blank unless you need to override what your ssh config already says. |
| **Port** | Leave blank for the default (22), or for whatever your ssh config specifies. |

Then add at least one forward — a tunnel with no forwards connects but carries nothing. Click
**Add Forward** and pick a type:

- **Local** — the common one. Opens a port *on your Mac* that reaches a service on the far side.
  To read a web console running on port 9090 of the remote machine, use listen port `9090`,
  destination `localhost:9090`, and then visit `http://localhost:9090` in your browser.
- **Remote** — the reverse. Opens a port *on the server* that reaches back to something on your
  Mac.
- **SOCKS** — a local SOCKS proxy on the port you choose, for pointing a browser through the
  remote machine. No destination needed.

Press **⌘S** to save, then **Start**.

### Saving

Nothing saves automatically. Tunaboat waits for you to press ⌘S or click **Save**, because
otherwise typing a port number would rewrite the file and restart a live tunnel on every keystroke.
While you have unsaved changes, the editor toolbar says **Unsaved changes** and the menu grows a
**Save Configuration** item.

**Deleting is the exception** — it takes effect immediately, stops the tunnel, and is written to
disk at once. It commits only the deletion, so any other edits you have in progress stay unsaved.

## Reading the status

Every tunnel shows a coloured dot, in the editor and in the menu:

| Colour | Meaning |
|---|---|
| 🟡 Yellow | Idle — not started. |
| 🟠 Orange | Working on it — connecting, authenticating, establishing forwards. |
| 🟢 Green | Connected, with every forward you asked for confirmed up. |
| 🔴 Red | Failed. The reason is written next to it. |

A green tunnel with a **⚠︎** is connected and working, but something it did not ask for went wrong
— almost always a forward that your `~/.ssh/config` adds for that host, over a port that is already
taken. Your own forwards are fine; the warning text says which port.

Green means the forwards are genuinely established, not merely that the connection opened. `ssh`
will happily report a healthy session whose every forward failed, and Tunaboat deliberately does
not call that connected.

The menu bar icon reflects the worst state among all your tunnels, so a failure is visible without
opening anything.

## Options

Per tunnel, in the **Options** panel:

- **Connect at launch** — start this tunnel automatically whenever Tunaboat starts.
- **Compression** — passes `-C` to ssh. Worth it on slow links, a waste of CPU on fast ones.
- **All interfaces** — by default a local forward only listens on your own machine. Turn this on to
  let other machines on your network reach it. Only do this on a network you trust.

## Starting at login

Menu bar icon → **Launch at Login**. Combine it with **Connect at launch** on individual tunnels
and your forwards come up by themselves after a restart.

macOS tracks this in **System Settings → General → Login Items**, where you can also turn it off.
If you switch it off there, Tunaboat cannot turn it back on for you — the menu item changes to
**Launch at Login — Open Settings…**, which takes you to the right place.

## Quitting takes your tunnels with it

Quitting Tunaboat closes every tunnel it opened, and this is on purpose. An ssh process that
outlives the app would go on holding its forwarded ports invisibly, and the next thing that tried
to use one of those ports would fail for no apparent reason.

So: if you need a forward to survive, leave Tunaboat running.

## Coming from SSH Tunnel Manager

If you used tynsoe's SSH Tunnel Manager, Tunaboat can read its connections:

```sh
tunaboat import --dry-run     # see what would be imported, change nothing
tunaboat import               # actually import
```

Tunnels whose names you already have are skipped rather than duplicated. Anything that could not be
translated faithfully is noted on the imported tunnel — click the ⓘ next to its Host field to read
it, rather than being silently dropped.

## The command line

The `tunaboat` command is inside the app. To use it from anywhere, link it onto your path once:

```sh
sudo ln -s /Applications/Tunaboat.app/Contents/Helpers/tunaboat /usr/local/bin/tunaboat
```

```sh
tunaboat list                 # every configured tunnel and its forwards
tunaboat show <name>          # print the exact ssh command that tunnel would run
tunaboat up <name>            # bring one up in the foreground; Ctrl-C stops it
tunaboat import [--dry-run]   # import from SSH Tunnel Manager
```

`tunaboat up` prints each state change as it happens, which makes it the quickest way to find out
why something will not connect. It keeps retrying a dropped connection; `--max-attempts N` makes it
give up instead. Ctrl-C shuts the tunnel down cleanly.

Every command takes `--config <path>` if you keep your tunnels somewhere other than the default.

`tunaboat show` is also useful on its own — it gives you a command you can paste into Terminal and
run by hand:

```
$ tunaboat show backend
/usr/bin/ssh -N -T -v -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -L 9090:localhost:9090 backend
```

The same command is available in the editor under **Command**, with a Copy button.

## Where your tunnels are stored

```
~/.config/tunaboat/tunnels.json
```

Plain JSON, on purpose: you can read it, diff it, keep it in a dotfiles repo, and edit it by hand
while nothing is running. The app and the command line both read this one file, so they never
disagree about what you have.

If you previously used this app under its old name, `~/.config/tmon/tunnels.json` is still read
when the new file does not exist yet, so your tunnels carry over. The old file is never modified or
deleted; the first save writes the new location.

A minimal example:

```json
[
  {
    "id": "1B9E4C2A-0000-4000-8000-000000000001",
    "name": "backend",
    "host": "backend",
    "forwards": [
      {
        "id": "1B9E4C2A-0000-4000-8000-000000000002",
        "kind": "local",
        "listenPort": 9090,
        "destinationHost": "localhost",
        "destinationPort": 9090
      }
    ],
    "autoConnect": true,
    "compression": false,
    "listenOnAllInterfaces": false,
    "keepAlive": { "intervalSeconds": 15, "maxMissed": 3 },
    "importWarnings": []
  }
]
```

`kind` is `local`, `remote`, or `dynamic` (SOCKS). Each `id` is any unique UUID. Use **Reload
Configuration** in the menu after editing the file by hand.

## Passwords and keys

Tunaboat never stores or asks for a private key, passphrase, or password, and never writes one to
its configuration or logs. Authentication is entirely `ssh`'s job, using your ssh-agent and
whatever the Keychain already holds. If a host works from Terminal, it works here.

## When something goes wrong

**"Port N: Address already in use"** — something else on your Mac already holds that local port.
Often it is another copy of the same tunnel. `lsof -nP -iTCP:N -sTCP:LISTEN` will name the culprit.

**Connected, but with a ⚠︎ about a port you never configured** — that forward comes from your
`~/.ssh/config`, not from Tunaboat. Your own forwards are up. Either free the port or remove the
`RemoteForward`/`LocalForward` line from your ssh config for that host.

**"Permission denied (publickey)"** — ssh could not authenticate. Test with
`ssh -v <host>` in Terminal; whatever fixes it there fixes it here.

**It says connected but nothing answers** — check the forward's *destination* is right as seen
**from the server**. `localhost` in a local forward means the far end's localhost, not yours.

**Nothing in the menu bar after launch** — Tunaboat has no Dock icon by design. If the menu bar is
crowded, macOS may be hiding it; try widening the bar or quitting another menu bar app.

For anything else, `tunaboat up <name>` in a terminal shows the full state progression and the
underlying reason.
