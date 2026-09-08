import Foundation
import Testing
@testable import TunaboatCore

@Suite("Tunnel state machine")
struct TunnelStateMachineTests {
    /// `owns` declares the local ports the tunnel asked for; a failure on any other port
    /// belongs to a forward inherited from ~/.ssh/config, not to us.
    private func machine(listeners: Int, owns: Set<Int> = [], ownsRemote: Set<Int> = []) -> TunnelStateMachine {
        var m = TunnelStateMachine(
            expectedListeners: listeners, ownedLocalPorts: owns, ownedRemotePorts: ownsRemote
        )
        m.started()
        return m
    }

    @Test("Climbs the ladder as forwards come up")
    func happyPath() {
        var m = machine(listeners: 2, owns: [9504, 8204])
        #expect(m.state == .connecting)
        m.apply(.authenticated(method: "publickey"))
        #expect(m.state == .authenticated)

        // The first claim is still outstanding — ssh has not yet shown whether it binds.
        m.apply(.forwardListening(port: 9504))
        #expect(m.state == .forwarding(established: 0, total: 2))

        // Moving to another port settles the first one.
        m.apply(.forwardListening(port: 8204))
        #expect(m.state == .forwarding(established: 1, total: 2))

        // Entering the session settles the last one and takes the verdict.
        m.apply(.interactiveSessionEntered)
        #expect(m.state == .connected)
    }

    @Test("Duplicate listener lines do not inflate the count")
    func duplicateListeners() {
        var m = machine(listeners: 2, owns: [9504, 8204])
        m.apply(.forwardListening(port: 9504))
        m.apply(.forwardListening(port: 9504))
        m.apply(.forwardListening(port: 8204))
        #expect(m.state == .forwarding(established: 1, total: 2))
    }

    @Test("A session with dead forwards is never reported as connected")
    func sessionUpButForwardsDead() {
        // The real backend failure: every requested port was taken locally, ssh entered
        // the interactive session anyway, and the tunnel carried nothing.
        var m = machine(listeners: 1, owns: [19090])
        m.apply(.forwardListening(port: 19090))
        m.apply(.bindFailed(address: "127.0.0.1", port: 19090, reason: "Address already in use"))
        m.apply(.cannotListen(port: 19090))
        m.apply(.interactiveSessionEntered)

        #expect(m.state != .connected)
        #expect(m.state == .forwarding(established: 0, total: 1))
        #expect(m.hasFatalForwardFailure)
    }

    @Test("A remote-only tunnel reaches connected on the interactive-session line")
    func remoteOnlyTunnel() {
        // -R forwards produce no "Local forwarding listening" lines, so a tunnel with
        // only remote forwards would otherwise never leave .authenticated.
        var m = machine(listeners: 0)
        m.apply(.authenticated(method: "publickey"))
        m.apply(.interactiveSessionEntered)
        #expect(m.state == .connected)
    }

    @Test("Auth failure is terminal — the bug where a wrong key retries forever")
    func authFailureIsNotRetryable() {
        var m = machine(listeners: 1)
        m.apply(.permissionDenied(methods: "publickey"))
        let state = m.exited(code: 255)
        guard case .failed(let failure) = state else { Issue.record("expected failure"); return }
        #expect(failure.kind == .authentication)
        #expect(failure.isRetryable == false)
        #expect(failure.message.contains("publickey"))
    }

    @Test("Host key failure is terminal and needs a human")
    func hostKeyIsNotRetryable() {
        var m = machine(listeners: 1)
        m.apply(.hostKeyVerificationFailed)
        guard case .failed(let f) = m.exited(code: 255) else { Issue.record("expected failure"); return }
        #expect(f.kind == .hostKey)
        #expect(f.isRetryable == false)
    }

    @Test("A bind collision reports which port, and does not retry into the same wall")
    func bindCollision() {
        var m = machine(listeners: 1, owns: [9504])
        m.apply(.bindFailed(address: "127.0.0.1", port: 9504, reason: "Address already in use"))
        m.apply(.cannotListen(port: 9504))
        #expect(m.hasFatalForwardFailure)
        guard case .failed(let f) = m.exited(code: 255) else { Issue.record("expected failure"); return }
        #expect(f.kind == .portInUse)
        #expect(f.message.contains("9504"))
        #expect(f.message.contains("Address already in use"))
        #expect(f.isRetryable == false)
    }

    @Test("A server-rejected remote forward is distinguished from a local collision")
    func remoteForwardRejection() {
        var m = machine(listeners: 0, ownsRemote: [4713])
        m.apply(.remoteForwardFailed(port: 4713))
        guard case .failed(let f) = m.exited(code: 255) else { Issue.record("expected failure"); return }
        #expect(f.kind == .remoteForwardRejected)
        #expect(f.isRetryable == false)
    }

    @Test("A drop after connecting is retryable, unlike every failure above")
    func dropAfterConnectIsRetryable() {
        var m = machine(listeners: 1, owns: [9504])
        m.apply(.forwardListening(port: 9504))
        m.apply(.interactiveSessionEntered)
        #expect(m.state == .connected)
        guard case .failed(let f) = m.exited(code: 255) else { Issue.record("expected failure"); return }
        #expect(f.kind == .network)
        #expect(f.isRetryable == true)
        #expect(f.message == "Connection lost")
    }

    @Test("A clean exit before connecting is a deliberate stop, not a failure")
    func cleanExitIsIdle() {
        var m = machine(listeners: 1)
        #expect(m.exited(code: 0) == .idle)
    }

    @Test("Network errors before connecting are retryable")
    func networkErrorRetryable() {
        var m = machine(listeners: 1)
        m.apply(.connectFailed(reason: "Connection refused"))
        guard case .failed(let f) = m.exited(code: 255) else { Issue.record("expected failure"); return }
        #expect(f.kind == .network)
        #expect(f.isRetryable == true)
    }
}


/// The real-world case found on this machine: `~/.ssh/config` carries
/// `Host backend / RemoteForward 9998 localhost:9998`, and that port is already bound on
/// the server. ssh reports the failure on every connection, but the tunnel itself is fine.
@Suite("Forward failures are attributed by port ownership")
struct ForwardOwnershipTests {
    private func machine(owns: Set<Int> = [], ownsRemote: Set<Int> = []) -> TunnelStateMachine {
        var m = TunnelStateMachine(
            expectedListeners: owns.count, ownedLocalPorts: owns, ownedRemotePorts: ownsRemote
        )
        m.started()
        return m
    }

    @Test("A config-file remote forward failing does not fail the tunnel")
    func foreignRemoteForwardIsAWarning() {
        var m = machine(owns: [5901])
        m.apply(.remoteForwardFailed(port: 9998))
        m.apply(.forwardListening(port: 5901))
        m.apply(.interactiveSessionEntered)

        #expect(m.state == .connected)
        #expect(m.hasFatalForwardFailure == false)
        #expect(m.warnings.count == 1)
        #expect(m.warnings[0].contains("9998"))
        #expect(m.warnings[0].contains("~/.ssh/config"))
    }

    @Test("Our own remote forward failing does fail the tunnel")
    func ownedRemoteForwardIsFatal() {
        var m = machine(ownsRemote: [4713])
        m.apply(.remoteForwardFailed(port: 4713))
        #expect(m.hasFatalForwardFailure)
        #expect(m.warnings.isEmpty)
        guard case .failed(let f) = m.exited(code: 255) else { Issue.record("expected failure"); return }
        #expect(f.kind == .remoteForwardRejected)
    }

    @Test("A collision on a port we did not request is a warning, and the tunnel stays up")
    func foreignBindFailureIsAWarning() {
        var m = machine(owns: [5901])
        // A forward from ~/.ssh/config, on a port Tunaboat knows nothing about.
        m.apply(.bindFailed(address: "127.0.0.1", port: 7777, reason: "Address already in use"))
        m.apply(.cannotListen(port: 7777))
        m.apply(.forwardListening(port: 5901))
        m.apply(.interactiveSessionEntered)

        #expect(m.state == .connected)
        #expect(m.hasFatalForwardFailure == false)
        #expect(m.warnings.count == 1)
        #expect(m.warnings[0].contains("7777"))
    }

    @Test("A collision on a port we requested is fatal")
    func ownedBindFailureIsFatal() {
        var m = machine(owns: [5901])
        m.apply(.bindFailed(address: "127.0.0.1", port: 5901, reason: "Address already in use"))
        // The bind line alone is not the verdict — see OptimisticListeningTests.
        #expect(m.hasFatalForwardFailure == false)
        m.apply(.cannotListen(port: 5901))
        #expect(m.hasFatalForwardFailure)
        #expect(m.warnings.isEmpty)
    }

    @Test("An unattributable rejection never fails the tunnel on its own")
    func unattributableRejection() {
        // "Could not request local forwarding." carries no port number, so failing on it
        // would mean blaming Tunaboat for a config-file forward.
        var m = machine(owns: [5901])
        m.apply(.forwardingRequestRejected)
        #expect(m.hasFatalForwardFailure == false)
        #expect(m.warnings.count == 1)
    }

    @Test("Warnings are cleared when the tunnel restarts")
    func warningsResetOnRestart() {
        var m = machine(owns: [5901])
        m.apply(.remoteForwardFailed(port: 9998))
        #expect(!m.warnings.isEmpty)
        m.started()
        #expect(m.warnings.isEmpty)
        #expect(m.hasFatalForwardFailure == false)
    }

    @Test("Ownership is derived from the spec, counting distinct local ports")
    func derivedFromSpec() {
        let spec = TunnelSpec(name: "y", host: "backend", forwards: [
            Forward(kind: .local, listenPort: 5901, destinationPort: 5901),
            Forward(kind: .local, listenPort: 19090, destinationPort: 9090),
            Forward(kind: .remote, listenPort: 4713, destinationPort: 4713),
            Forward(kind: .dynamic, listenPort: 1080),
        ])
        let m = TunnelStateMachine(spec: spec)
        #expect(m.ownedLocalPorts == [5901, 19090, 1080])
        #expect(m.ownedRemotePorts == [4713])
        #expect(m.expectedListeners == 3)
    }
}

/// ssh announces a forward as listening *before* it binds, and does not retract the
/// announcement when the bind fails. Sequences here are transcribed from a real
/// OpenSSH 10.3p1 run against a host where the local ports were already taken.
@Suite("A listening line is a claim, not a verdict")
struct OptimisticListeningTests {
    private func machine(owns: Set<Int>) -> TunnelStateMachine {
        var m = TunnelStateMachine(
            expectedListeners: owns.count, ownedLocalPorts: owns, ownedRemotePorts: []
        )
        m.started()
        return m
    }

    @Test("A port that announces then fails to bind does not count as established")
    func announcedThenFailed() {
        var m = machine(owns: [19090, 25672])
        // Real sequence for a busy port.
        m.apply(.forwardListening(port: 19090))
        m.apply(.bindFailed(address: "::1", port: 19090, reason: "Address already in use"))
        m.apply(.forwardListening(port: 19090))
        m.apply(.bindFailed(address: "127.0.0.1", port: 19090, reason: "Address already in use"))
        m.apply(.cannotListen(port: 19090))

        #expect(m.state == .forwarding(established: 0, total: 2))
        #expect(m.hasFatalForwardFailure)
    }

    @Test("The failure message names the port and the real reason")
    func failureMessage() {
        var m = machine(owns: [19090])
        m.apply(.forwardListening(port: 19090))
        m.apply(.bindFailed(address: "127.0.0.1", port: 19090, reason: "Address already in use"))
        m.apply(.cannotListen(port: 19090))
        guard case .failed(let f) = m.exited(code: 255) else { Issue.record("expected failure"); return }
        #expect(f.kind == .portInUse)
        #expect(f.message.contains("19090"))
        #expect(f.message.contains("Address already in use"))
    }

    @Test("An IPv6 bind failure alone does not fail a forward that works on IPv4")
    func ipv6OnlyBindFailureIsSurvivable() {
        // Common on hosts with ::1 unavailable: ssh reports the ::1 bind failing, binds
        // 127.0.0.1 fine, and never emits "cannot listen". The forward works.
        var m = machine(owns: [19090])
        m.apply(.forwardListening(port: 19090))
        m.apply(.bindFailed(address: "::1", port: 19090, reason: "Cannot assign requested address"))
        m.apply(.forwardListening(port: 19090))
        m.apply(.interactiveSessionEntered)
        // No "cannot listen" ever arrives, so the forward is real.

        #expect(m.state == .connected)
        #expect(m.hasFatalForwardFailure == false)
        #expect(m.warnings.isEmpty)
    }

    @Test("Both address families listening for one port still counts once")
    func duplicateFamiliesCountOnce() {
        var m = machine(owns: [19090, 25672])
        m.apply(.forwardListening(port: 19090))
        m.apply(.forwardListening(port: 19090))
        m.apply(.forwardListening(port: 25672))
        m.apply(.forwardListening(port: 25672))
        #expect(m.state == .forwarding(established: 1, total: 2))
        m.apply(.interactiveSessionEntered)
        #expect(m.state == .connected)
    }

    @Test("Progress never goes backwards while forwards are being set up")
    func progressIsMonotonic() {
        // The naive implementation counted a claim immediately and removed it on failure,
        // so the CLI printed 1 of 3 → 0 of 3 → 1 of 3 → 0 of 3.
        var m = machine(owns: [19090, 25672, 15901])
        var counts: [Int] = []
        func record() {
            if case .forwarding(let established, _) = m.state { counts.append(established) }
        }
        for port in [19090, 25672, 15901] {
            m.apply(.forwardListening(port: port)); record()
            m.apply(.bindFailed(address: "::1", port: port, reason: "Address already in use")); record()
            m.apply(.forwardListening(port: port)); record()
            m.apply(.bindFailed(address: "127.0.0.1", port: port, reason: "Address already in use")); record()
            m.apply(.cannotListen(port: port)); record()
        }
        #expect(counts.allSatisfy { $0 == 0 }, "saw \(counts)")
    }

    @Test("A late listening line cannot resurrect a port already ruled out")
    func lateLineAfterFailure() {
        var m = machine(owns: [19090])
        m.apply(.cannotListen(port: 19090))
        m.apply(.forwardListening(port: 19090))
        #expect(m.state == .forwarding(established: 0, total: 1))
    }

    @Test("Connected is sticky against later chatter")
    func connectedIsSticky() {
        var m = machine(owns: [19090])
        m.apply(.forwardListening(port: 19090))
        m.apply(.interactiveSessionEntered)
        #expect(m.state == .connected)
        m.apply(.forwardListening(port: 19090))
        #expect(m.state == .connected)
    }
}
