import Foundation
import Testing
@testable import TunaboatCore

/// A scripted stand-in for ssh: emits fixed stderr lines, then exits with a fixed code.
private actor FakeSSHProcess: SSHProcess {
    private let lines: [String]
    private let code: Int32

    init(lines: [String], code: Int32) {
        self.lines = lines
        self.code = code
    }

    func stderrLines() -> AsyncStream<String> {
        let lines = self.lines
        return AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    func waitUntilExit() async -> Int32 { code }
    func terminate() {}
}

/// Launcher over a scripted sequence of ssh runs, with an actor-isolated launch counter
/// so retry behaviour is observable.
private struct ScriptedLauncher: SSHLauncher {
    let script: Script

    actor Script {
        private let runs: [(lines: [String], code: Int32)]
        private var index = 0
        private(set) var launchCount = 0

        init(_ runs: [(lines: [String], code: Int32)]) { self.runs = runs }

        func next() -> (lines: [String], code: Int32) {
            launchCount += 1
            let run = runs[min(index, runs.count - 1)]
            index += 1
            return run
        }
    }

    func launch(_ command: SSHCommand) throws -> any SSHProcess {
        // The supervisor awaits everything it gets back, so returning a process that
        // pulls its script lazily keeps this synchronous requirement satisfiable.
        LazyScriptedProcess(script: script)
    }

    private actor LazyScriptedProcess: SSHProcess {
        let script: Script
        private var run: (lines: [String], code: Int32)?

        init(script: Script) { self.script = script }

        private func resolve() async -> (lines: [String], code: Int32) {
            if let run { return run }
            let resolved = await script.next()
            run = resolved
            return resolved
        }

        func stderrLines() async -> AsyncStream<String> {
            let lines = await resolve().lines
            return AsyncStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            }
        }

        func waitUntilExit() async -> Int32 { await resolve().code }
        func terminate() {}
    }
}

@Suite("Tunnel supervisor")
struct TunnelSupervisorTests {
    private func spec(forwards: [Forward] = [Forward(kind: .local, listenPort: 9504, destinationPort: 5901)]) -> TunnelSpec {
        TunnelSpec(name: "t", host: "h", forwards: forwards)
    }

    /// Collects states until `predicate` holds, or fails the test on timeout.
    private func waitForState(
        _ supervisor: TunnelSupervisor,
        timeout: Duration = .seconds(5),
        where predicate: @escaping @Sendable (TunnelStatus) -> Bool
    ) async -> TunnelStatus? {
        await withTaskGroup(of: TunnelStatus?.self) { group in
            group.addTask {
                for await status in await supervisor.states() where predicate(status) {
                    return status
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test("Reaches connected when the forward comes up")
    func reachesConnected() async {
        let script = ScriptedLauncher.Script([(
            lines: [
                #"debug1: Authenticated to h ([1.2.3.4]:22) using "publickey"."#,
                "debug1: Local forwarding listening on 127.0.0.1 port 9504.",
                "debug1: Entering interactive session.",
            ],
            code: 0
        )])
        let supervisor = TunnelSupervisor(
            spec: spec(),
            launcher: ScriptedLauncher(script: script),
            policy: .none
        )
        await supervisor.start()
        let status = await waitForState(supervisor) { $0.state == .connected }
        #expect(status?.state == .connected)
    }

    @Test("An auth failure is not retried")
    func authFailureDoesNotRetry() async {
        let script = ScriptedLauncher.Script([(
            lines: ["user@h: Permission denied (publickey)."],
            code: 255
        )])
        let supervisor = TunnelSupervisor(
            spec: spec(),
            launcher: ScriptedLauncher(script: script),
            policy: RetryPolicy(maxAttempts: 5, baseDelay: .milliseconds(1))
        )
        await supervisor.start()
        let status = await waitForState(supervisor) {
            if case .failed = $0.state { return true } else { return false }
        }
        guard case .failed(let failure) = status?.state else { Issue.record("expected failure"); return }
        #expect(failure.kind == .authentication)

        // Give a retry every chance to happen before asserting it did not.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await script.launchCount == 1)
    }

    @Test("A dropped connection is retried, and recovery clears the failure")
    func retriesAfterDrop() async {
        let script = ScriptedLauncher.Script([
            (lines: [
                "debug1: Local forwarding listening on 127.0.0.1 port 9504.",
                "debug1: Entering interactive session.",
             ], code: 255),
            (lines: [
                "debug1: Local forwarding listening on 127.0.0.1 port 9504.",
                "debug1: Entering interactive session.",
             ], code: 0),
        ])
        let supervisor = TunnelSupervisor(
            spec: spec(),
            launcher: ScriptedLauncher(script: script),
            policy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1), maxDelay: .milliseconds(5))
        )
        await supervisor.start()
        _ = await waitForState(supervisor) {
            if case .reconnecting = $0.state { return true } else { return false }
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await script.launchCount >= 2)
    }

    @Test("stop() puts the tunnel back to idle")
    func stopReturnsToIdle() async {
        let script = ScriptedLauncher.Script([(
            lines: [
                "debug1: Local forwarding listening on 127.0.0.1 port 9504.",
                "debug1: Entering interactive session.",
            ],
            code: 0
        )])
        let supervisor = TunnelSupervisor(
            spec: spec(),
            launcher: ScriptedLauncher(script: script),
            policy: .none
        )
        await supervisor.start()
        _ = await waitForState(supervisor) { $0.state == .connected }
        await supervisor.stop()
        #expect(await supervisor.state == .idle)
    }
}

@Suite("Retry policy")
struct RetryPolicyTests {
    @Test("Backoff grows exponentially and then caps")
    func backoff() {
        let policy = RetryPolicy(baseDelay: .seconds(1), maxDelay: .seconds(30))
        #expect(policy.delay(forAttempt: 1) == .seconds(1))
        #expect(policy.delay(forAttempt: 2) == .seconds(2))
        #expect(policy.delay(forAttempt: 3) == .seconds(4))
        #expect(policy.delay(forAttempt: 6) == .seconds(30))
        #expect(policy.delay(forAttempt: 99) == .seconds(30))
    }

    @Test("Attempt limits are honoured, including zero")
    func limits() {
        #expect(RetryPolicy.none.shouldRetry(attempt: 1) == false)
        #expect(RetryPolicy.default.shouldRetry(attempt: 1_000) == true)
        #expect(RetryPolicy(maxAttempts: 2).shouldRetry(attempt: 2) == true)
        #expect(RetryPolicy(maxAttempts: 2).shouldRetry(attempt: 3) == false)
    }
}

@Suite("Supervisor state publishing")
struct SupervisorPublishingTests {
    @Test("Observers do not see repeated identical states")
    func noDuplicateStates() async {
        // "Host key verification failed." records a cause without changing state, so a
        // naive implementation republishes .connecting and the UI flickers.
        let script = ScriptedLauncher.Script([(
            lines: [
                "debug1: Connecting to h port 22.",
                "Host key verification failed.",
            ],
            code: 255
        )])
        let supervisor = TunnelSupervisor(
            spec: TunnelSpec(name: "t", host: "h",
                             forwards: [Forward(kind: .local, listenPort: 1, destinationPort: 2)]),
            launcher: ScriptedLauncher(script: script),
            policy: .none
        )
        let states = await supervisor.states()
        await supervisor.start()

        let collector = Task {
            var collected: [TunnelStatus] = []
            for await status in states {
                collected.append(status)
                if case .failed = status.state { break }
            }
            return collected
        }
        let seen = await collector.value

        #expect(seen.count == zip(seen, seen.dropFirst()).filter { $0 != $1 }.count + 1,
                "adjacent duplicates in \(seen.map(\.state.summary))")
        #expect(seen.first?.state == .idle)
        if case .failed(let f) = seen.last?.state { #expect(f.kind == .hostKey) } else { Issue.record("expected failure") }
    }
}

@Suite("Supervisor ends a session whose forwards are dead")
struct DeadForwardTerminationTests {
    @Test("A session with a failed owned forward is failed, never reported connected")
    func deadForwardIsNotConnected() async {
        // Transcribed from the live backend run: ssh authenticates, announces the
        // forward, fails to bind it, and enters the interactive session regardless.
        let script = ScriptedLauncher.Script([(
            lines: [
                #"Authenticated to backend.example ([192.0.2.10]:22) using "publickey"."#,
                "debug1: Local forwarding listening on ::1 port 19090.",
                "bind [::1]:19090: Address already in use",
                "debug1: Local forwarding listening on 127.0.0.1 port 19090.",
                "bind [127.0.0.1]:19090: Address already in use",
                "channel_setup_fwd_listener_tcpip: cannot listen to port: 19090",
                "debug1: Entering interactive session.",
            ],
            code: 255
        )])
        let supervisor = TunnelSupervisor(
            spec: TunnelSpec(name: "backend", host: "backend", forwards: [
                Forward(kind: .local, listenPort: 19090, destinationPort: 9090),
            ]),
            launcher: ScriptedLauncher(script: script),
            policy: .none
        )

        let states = await supervisor.states()
        await supervisor.start()
        let collector = Task {
            var seen: [TunnelStatus] = []
            for await status in states {
                seen.append(status)
                if case .failed = status.state { break }
            }
            return seen
        }
        let seen = await collector.value

        #expect(!seen.contains { $0.state == .connected }, "never claim connected: \(seen.map(\.state.summary))")
        guard case .failed(let failure) = seen.last?.state else { Issue.record("expected failure"); return }
        #expect(failure.kind == .portInUse)
        #expect(failure.message.contains("19090"))
    }
}

/// A stand-in for a *live* ssh: emits its output, then stays running until terminated —
/// unlike ScriptedLauncher, whose processes exit as soon as their lines are consumed.
private actor HangingSSHProcess: SSHProcess {
    private let lines: [String]
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var exitCode: Int32?

    init(lines: [String]) { self.lines = lines }

    func stderrLines() -> AsyncStream<String> {
        let lines = self.lines
        return AsyncStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }

    func waitUntilExit() async -> Int32 {
        if let exitCode { return exitCode }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func terminate() {
        guard exitCode == nil else { return }
        exitCode = 143
        for waiter in waiters { waiter.resume(returning: 143) }
        waiters.removeAll()
    }
}

private final class HangingLauncher: SSHLauncher {
    private let lines: [String]
    private let counter = Counter()

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    init(lines: [String]) { self.lines = lines }

    var launchCount: Int {
        get async { await counter.value }
    }

    func launch(_ command: SSHCommand) throws -> any SSHProcess {
        let process = HangingSSHProcess(lines: lines)
        Task { await counter.increment() }
        return process
    }
}

@Suite("Recovering from a failure")
struct RestartAfterFailureTests {
    /// Reported: after a tunnel failed with "Port 5901: Address already in use", the Start
    /// button did nothing and there was no way to clear the error. The completed run task was
    /// never released, so every later `start()` returned immediately.
    @Test("A failed tunnel can be started again")
    func startAfterFailure() async {
        let script = ScriptedLauncher.Script([
            (lines: [
                "debug1: Local forwarding listening on 127.0.0.1 port 5901.",
                "bind [127.0.0.1]:5901: Address already in use",
                "channel_setup_fwd_listener_tcpip: cannot listen to port: 5901",
             ], code: 255),
            (lines: [
                "debug1: Local forwarding listening on 127.0.0.1 port 5901.",
                "debug1: Entering interactive session.",
             ], code: 0),
        ])
        let supervisor = TunnelSupervisor(
            spec: TunnelSpec(name: "backend", host: "backend", forwards: [
                Forward(kind: .local, listenPort: 5901, destinationPort: 5901),
            ]),
            launcher: ScriptedLauncher(script: script),
            policy: .none
        )

        let first = await supervisor.states()
        await supervisor.start()
        let failed = Task {
            for await status in first {
                if case .failed = status.state { return status }
            }
            return TunnelStatus(state: .idle)
        }
        _ = await failed.value
        #expect(await supervisor.isRunning == false, "a finished run must release its slot")

        // The port has since been freed; starting again must actually relaunch ssh.
        let second = await supervisor.states()
        await supervisor.start()
        let recovered = Task {
            for await status in second where status.state == .connected { return true }
            return false
        }
        #expect(await recovered.value)
        #expect(await script.launchCount == 2)
    }

    @Test("Clicking start twice does not launch a second ssh")
    func startIsIdempotentWhileRunning() async {
        // A second ssh would collide with the first on its own forwarded port and report
        // "Address already in use" against a tunnel that is actually working.
        let launcher = HangingLauncher(lines: [
            "debug1: Local forwarding listening on 127.0.0.1 port 5901.",
            "debug1: Entering interactive session.",
        ])
        let supervisor = TunnelSupervisor(
            spec: TunnelSpec(name: "y", host: "y", forwards: [
                Forward(kind: .local, listenPort: 5901, destinationPort: 5901),
            ]),
            launcher: launcher,
            policy: .none
        )
        let states = await supervisor.states()
        await supervisor.start()
        let up = Task {
            for await status in states where status.state == .connected { return true }
            return false
        }
        #expect(await up.value)
        #expect(await supervisor.isRunning)

        await supervisor.start()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await launcher.launchCount == 1)

        await supervisor.stop()
        #expect(await supervisor.isRunning == false)
    }
}
