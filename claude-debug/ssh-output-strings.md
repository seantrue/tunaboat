# OpenSSH stderr strings the parser depends on

Every pattern in `SSHOutputParser` was verified on this machine against **OpenSSH_10.3p1**,
either captured verbatim from a live run or read out of `/usr/bin/ssh`'s own format strings
(`strings -a /usr/bin/ssh`). None were written from memory.

## Captured verbatim from a live `ssh -v`

```
ssh: Could not resolve hostname nonexistent.invalid: nodename nor servname provided, or not known
ssh: connect to host localhost port 1: Connection refused
debug1: connect to address 127.0.0.1 port 1: Connection refused
debug1: Authentications that can continue: publickey,password,keyboard-interactive
user@localhost: Permission denied (publickey,password,keyboard-interactive).
Host key verification failed.
```

## Format strings read out of the ssh binary

```
Authenticated to %s ([%s]:%d) using "%s".
Local forwarding listening on %s port %s.
Entering interactive session.
bind [%s]:%s: %.100s
cannot listen to port: %d
Warning: remote port forwarding failed for listen port %d
Error: remote port forwarding failed for listen port %d
Could not request local forwarding.
Warning: Could not request remote forwarding.
```

Note `Address already in use` is not in the binary — it arrives via `strerror(errno)` as the
`%.100s` of the `bind [%s]:%s: %.100s` line, so the parser must treat the reason as free text
rather than matching a fixed string.

## Verified against a live connection to `backend`

> Host names and addresses here are stand-ins (`backend`, `appserver`, `192.0.2.x`). The
> captures are real OpenSSH 10.3p1 output; only the identifiers were replaced.

All of the above is now confirmed against a real multi-service tunnel (cockpit 9090, rabbitmq
15672, VNC 5901), including live HTTP 200 responses through the forwards.

### The ordering that matters

A **successful** forward:

```
debug1: Local forwarding listening on ::1 port 19090.
debug1: Local forwarding listening on 127.0.0.1 port 19090.
```

A **failed** forward — note the listening line is printed first anyway, and never retracted:

```
debug1: Local forwarding listening on ::1 port 19090.
bind [::1]:19090: Address already in use
debug1: Local forwarding listening on 127.0.0.1 port 19090.
bind [127.0.0.1]:19090: Address already in use
channel_setup_fwd_listener_tcpip: cannot listen to port: 19090
```

Consequences the parser depends on:

1. Two listening lines are emitted per forward (one per address family), so counting lines
   overcounts; count distinct ports.
2. A listening line is a *claim*. Only the absence of a later `cannot listen to port: N`
   confirms it.
3. `bind` failures are per-family. A `::1` failure with a `127.0.0.1` success is a working
   forward and must not fail the tunnel.
4. `Entering interactive session.` is printed **even when every forward failed**, because we do
   not pass `ExitOnForwardFailure`. It marks the session, not the tunnel.

### Forwards inherited from `~/.ssh/config`

`Host backend` in this user's config carries `RemoteForward 9998 localhost:9998`. When 9998 is
already bound on the server, every Tunaboat connection sees:

```
Warning: remote port forwarding failed for listen port 9998
```

With `ExitOnForwardFailure=yes` this killed the tunnel outright — a forward Tunaboat never requested
taking down a working connection. `ClearAllForwardings=yes` is not a fix: it clears the
command-line `-L` flags too (verified). Hence attribution by port ownership.

## Reproducing

```sh
ssh -v -N -o BatchMode=yes -o ConnectTimeout=3 nonexistent.invalid
ssh -v -N -o BatchMode=yes -o ConnectTimeout=3 -p 1 localhost
swift run tunaboat up e2e-authfail --config claude-debug/e2e-localhost-tunnels.json
```
