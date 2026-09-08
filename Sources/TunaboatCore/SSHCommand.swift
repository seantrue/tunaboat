import Foundation

/// Turns a ``TunnelSpec`` into an argv for `/usr/bin/ssh`.
///
/// Pure and synchronous on purpose: argv construction is the part most worth testing,
/// and it must be verifiable without spawning anything.
public struct SSHCommand: Sendable, Equatable {
    public static let executable = "/usr/bin/ssh"

    public var arguments: [String]

    /// - Parameters:
    ///   - interactive: when false, adds `BatchMode=yes` so a missing key fails fast
    ///     instead of blocking on a prompt with no way to answer it.
    ///   - verbose: adds `-v`, whose stderr is what the supervisor reads to tell
    ///     "authenticated and forwarding" from "process merely alive".
    ///   - exitOnForwardFailure: see the note below. Defaults to `false` deliberately.
    public init(
        spec: TunnelSpec,
        interactive: Bool = true,
        verbose: Bool = true,
        exitOnForwardFailure: Bool = false
    ) {
        var args: [String] = ["-N", "-T"]

        if verbose { args.append("-v") }

        // NOT `ExitOnForwardFailure=yes` by default, despite it being the obvious choice.
        //
        // ssh merges forwards from `~/.ssh/config` with the ones we pass, and we cannot
        // separate them: `ClearAllForwardings=yes` drops our own `-L` flags too (verified
        // against OpenSSH 10.3p1). So ExitOnForwardFailure hands a config-file forward the
        // power to kill a tunnel over a port Tunaboat never configured — which is exactly what
        // happens on a host whose config carries a `RemoteForward` that is already bound.
        //
        // Instead ``TunnelStateMachine`` watches the forward-failure lines and decides by
        // *port ownership*: a port we asked for is fatal, a port we did not is a warning.
        // That yields the same protection against a silently dead forward, and attributes
        // the failure correctly. See `claude-debug/ssh-output-strings.md`.
        if exitOnForwardFailure {
            args += ["-o", "ExitOnForwardFailure=yes"]
        }
        args += ["-o", "ServerAliveInterval=\(spec.keepAlive.intervalSeconds)"]
        args += ["-o", "ServerAliveCountMax=\(spec.keepAlive.maxMissed)"]

        if !interactive {
            args += ["-o", "BatchMode=yes"]
        }
        if spec.listenOnAllInterfaces {
            args += ["-o", "GatewayPorts=yes"]
        }
        if spec.compression {
            args.append("-C")
        }
        if let port = spec.port {
            args += ["-p", String(port)]
        }

        for forward in spec.forwards {
            args += [forward.flag, forward.argumentValue]
        }

        args.append(spec.destination)
        self.arguments = args
    }

    /// Copy-pasteable equivalent, for the UI's "reveal the command" affordance.
    public var displayCommand: String {
        ([Self.executable] + arguments)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
    }
}
