import Foundation

/// Why a tunnel is not running.
public struct TunnelFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Wrong or missing credentials. Retrying changes nothing.
        case authentication
        /// Host key mismatch or unknown. Needs a human decision, never an automatic retry.
        case hostKey
        /// A local listening port was already taken.
        case portInUse
        /// The server refused a `-R` forward, usually because the port is taken there.
        case remoteForwardRejected
        /// DNS, refused connection, unreachable network.
        case network
        /// ssh exited without us classifying why.
        case sshExited
    }

    public var kind: Kind
    /// Shown inline in the menu — a red dot you must open Console to explain is useless.
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// Whether an automatic reconnect could plausibly succeed.
    ///
    /// This is the distinction STM lacks: it shows "Reconnecting…" for a wrong passphrase
    /// and retries forever.
    public var isRetryable: Bool {
        switch kind {
        case .authentication, .hostKey, .portInUse, .remoteForwardRejected: false
        case .network, .sshExited: true
        }
    }
}

/// The status ladder, modelled on SSH Tunnel Manager's but with classified failures.
public enum TunnelState: Sendable, Equatable {
    case idle
    case connecting
    case authenticated
    /// Some but not all local listeners are up.
    case forwarding(established: Int, total: Int)
    case connected
    case reconnecting(attempt: Int)
    case failed(TunnelFailure)

    public var isActive: Bool {
        switch self {
        case .connecting, .authenticated, .forwarding, .connected, .reconnecting: true
        case .idle, .failed: false
        }
    }

    public var summary: String {
        switch self {
        case .idle: "Idle"
        case .connecting: "Connecting…"
        case .authenticated: "Authenticated"
        case .forwarding(let done, let total): "\(done) of \(total) ports forwarded"
        case .connected: "Connected"
        case .reconnecting(let n): "Reconnecting… (attempt \(n))"
        case .failed(let failure): failure.message
        }
    }
}

/// A state plus any non-fatal problems worth showing alongside it.
///
/// Warnings exist because a forward inherited from `~/.ssh/config` can fail without the
/// tunnel being broken: the user should see it, but the tunnel should not go red.
public struct TunnelStatus: Sendable, Equatable {
    public var state: TunnelState
    public var warnings: [String]

    public init(state: TunnelState, warnings: [String] = []) {
        self.state = state
        self.warnings = warnings
    }
}

/// Folds ssh output events and process exits into a ``TunnelState``.
///
/// Deliberately a pure value type: the interesting behaviour — that a bind collision is
/// terminal while a dropped network is not — is testable without a `Process`.
public struct TunnelStateMachine: Sendable {
    public private(set) var state: TunnelState = .idle

    /// Number of `-L`/`-D` forwards, i.e. how many distinct local ports we expect to see
    /// listening. `-R` forwards are set up by the server and are not counted here.
    public let expectedListeners: Int

    /// Local ports this tunnel asked for. A bind failure on one of these is ours to own.
    public let ownedLocalPorts: Set<Int>
    /// Server-side ports this tunnel asked for, via `-R`.
    public let ownedRemotePorts: Set<Int>

    /// Problems that are not this tunnel's fault and must not fail it — chiefly forwards
    /// that came from `~/.ssh/config`.
    public private(set) var warnings: [String] = []

    /// True once a forward *we* requested has failed. ssh is not necessarily going to exit
    /// on its own (we do not set ExitOnForwardFailure), so the supervisor must terminate it.
    public private(set) var hasFatalForwardFailure = false

    /// Ports confirmed listening — announced, and not subsequently ruled out.
    private var confirmedPorts: Set<Int> = []
    /// The port ssh most recently *claimed*, still awaiting confirmation. ssh emits
    /// `listening` → (`bind` attempts) → optional `cannot listen` contiguously per forward,
    /// so a claim is settled once ssh moves on to another port or enters the session.
    private var pendingPort: Int?
    /// Ports ssh definitively could not listen on. A port here never counts as established,
    /// even though ssh already announced it as listening.
    private var failedPorts: Set<Int> = []
    /// Per-port bind reasons, kept only to build a better message when the port ultimately
    /// fails. A bind failure alone is not a verdict.
    private var bindReasons: [Int: String] = [:]
    /// Set when we saw a specific cause, so a later exit is reported as that cause rather
    /// than a generic "ssh exited".
    private var pendingFailure: TunnelFailure?

    public init(expectedListeners: Int, ownedLocalPorts: Set<Int> = [], ownedRemotePorts: Set<Int> = []) {
        self.expectedListeners = expectedListeners
        self.ownedLocalPorts = ownedLocalPorts
        self.ownedRemotePorts = ownedRemotePorts
    }

    public init(spec: TunnelSpec) {
        let local = spec.forwards.filter { $0.kind != .remote }
        let remote = spec.forwards.filter { $0.kind == .remote }
        self.init(
            expectedListeners: Set(local.map(\.listenPort)).count,
            ownedLocalPorts: Set(local.map(\.listenPort)),
            ownedRemotePorts: Set(remote.map(\.listenPort))
        )
    }

    public var status: TunnelStatus { TunnelStatus(state: state, warnings: warnings) }

    public mutating func started() {
        state = .connecting
        confirmedPorts.removeAll()
        pendingPort = nil
        failedPorts.removeAll()
        bindReasons.removeAll()
        pendingFailure = nil
        warnings.removeAll()
        hasFatalForwardFailure = false
    }

    /// Promotes the outstanding claim to confirmed, unless it was ruled out.
    private mutating func settlePendingPort() {
        if let pendingPort, !failedPorts.contains(pendingPort) {
            confirmedPorts.insert(pendingPort)
        }
        pendingPort = nil
    }

    /// Recomputes the forwarding rung from the ports actually confirmed listening.
    ///
    /// `.connected` requires every forward this tunnel asked for to be up — a session with
    /// dead forwards is precisely the "looks healthy, carries nothing" state to avoid.
    /// It is sticky once reached: a late line must not drag a live tunnel backwards.
    private mutating func recomputeForwardingState(sessionEstablished: Bool = false) {
        guard state != .connected else { return }
        if confirmedPorts.count >= expectedListeners && (sessionEstablished || expectedListeners > 0) {
            state = .connected
        } else {
            state = .forwarding(established: confirmedPorts.count, total: expectedListeners)
        }
    }

    /// A port we did not ask for failed. Record it, but do not fail the tunnel.
    private mutating func noteForeignFailure(_ message: String) {
        if !warnings.contains(message) { warnings.append(message) }
    }

    @discardableResult
    public mutating func apply(_ event: SSHEvent) -> TunnelState {
        switch event {
        case .authenticated:
            if case .connecting = state { state = .authenticated }

        case .forwardListening(let port):
            // NOT proof of anything yet. ssh prints this line *before* attempting the bind,
            // and prints it even when the bind then fails — verified against OpenSSH 10.3p1,
            // where a busy port yields "listening", then "bind: Address already in use",
            // then "cannot listen to port". Only the absence of a later `cannot listen`
            // makes it real.
            guard !failedPorts.contains(port) else { break }
            // Two lines arrive per forward (::1 then 127.0.0.1); the same port is one claim.
            if pendingPort != port {
                settlePendingPort()
                pendingPort = port
            }
            recomputeForwardingState()

        case .interactiveSessionEntered:
            // ssh enters the interactive session even when forwards failed — we do not set
            // ExitOnForwardFailure. So this marks the *session* being up, not the tunnel.
            // It is, however, the point at which every forward has been attempted, so the
            // outstanding claim can be settled and the verdict taken.
            settlePendingPort()
            recomputeForwardingState(sessionEstablished: true)

        case .bindFailed(_, let port, let reason):
            // ssh binds each address family separately (::1 then 127.0.0.1). One failing
            // while the other succeeds still leaves a working forward, so this is evidence,
            // not a verdict. Keep the reason for the message if the port does fail outright.
            if let port { bindReasons[port] = reason }

        case .cannotListen(let port):
            // This is the verdict: the forward did not come up.
            failedPorts.insert(port)
            confirmedPorts.remove(port)
            if pendingPort == port { pendingPort = nil }
            recomputeForwardingState()

            let reason = bindReasons[port] ?? "could not listen"
            guard ownedLocalPorts.contains(port) else {
                noteForeignFailure("Forward from ~/.ssh/config failed — port \(port): \(reason)")
                break
            }
            hasFatalForwardFailure = true
            if pendingFailure == nil {
                pendingFailure = TunnelFailure(kind: .portInUse, message: "Port \(port): \(reason)")
            }

        case .remoteForwardFailed(let port):
            // The common real-world case: a RemoteForward in ~/.ssh/config whose server-side
            // port is already bound. Not Tunaboat's forward, so not Tunaboat's failure.
            guard ownedRemotePorts.contains(port) else {
                noteForeignFailure(
                    "Remote forward on port \(port) from ~/.ssh/config was refused by the server"
                )
                break
            }
            pendingFailure = TunnelFailure(
                kind: .remoteForwardRejected,
                message: "Server refused remote forward on port \(port)"
            )
            hasFatalForwardFailure = true

        case .forwardingRequestRejected:
            // Carries no port, so it cannot be attributed. The bind/cannot-listen lines that
            // accompany it do carry one; rely on those rather than failing blind.
            noteForeignFailure("ssh refused a forwarding request (no port reported)")

        case .permissionDenied(let methods):
            pendingFailure = TunnelFailure(
                kind: .authentication,
                message: methods.map { "Authentication failed (\($0))" } ?? "Authentication failed"
            )

        case .hostKeyVerificationFailed:
            pendingFailure = TunnelFailure(
                kind: .hostKey,
                message: "Host key verification failed"
            )

        case .connectFailed(let reason):
            pendingFailure = TunnelFailure(kind: .network, message: reason)

        case .nameResolutionFailed(let host):
            pendingFailure = TunnelFailure(kind: .network, message: "Cannot resolve \(host)")
        }
        return state
    }

    /// Folds in ssh's exit. `wasConnected` distinguishes "never came up" from "dropped".
    @discardableResult
    public mutating func exited(code: Int32) -> TunnelState {
        let wasConnected = state == .connected

        if let failure = pendingFailure {
            state = .failed(failure)
        } else if code == 0 && !wasConnected {
            // ssh -N exiting 0 without ever connecting means it was asked to stop.
            state = .idle
        } else {
            state = .failed(TunnelFailure(
                kind: wasConnected ? .network : .sshExited,
                message: wasConnected
                    ? "Connection lost"
                    : "ssh exited with status \(code)"
            ))
        }
        return state
    }

    public mutating func stopped() {
        state = .idle
        pendingFailure = nil
        confirmedPorts.removeAll()
        pendingPort = nil
        failedPorts.removeAll()
        bindReasons.removeAll()
        warnings.removeAll()
        hasFatalForwardFailure = false
    }

    public mutating func retrying(attempt: Int) {
        state = .reconnecting(attempt: attempt)
    }
}
