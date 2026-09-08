import Foundation

/// How aggressively to reconnect after a *retryable* failure.
public struct RetryPolicy: Sendable, Equatable {
    /// `nil` means keep trying indefinitely.
    public var maxAttempts: Int?
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(maxAttempts: Int? = nil, baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(30)) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 0)

    /// Exponential, capped. `attempt` is 1-based.
    public func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 1 else { return baseDelay }
        let factor = 1 << min(attempt - 1, 16)
        let scaled = baseDelay * factor
        return scaled > maxDelay ? maxDelay : scaled
    }

    public func shouldRetry(attempt: Int) -> Bool {
        guard let maxAttempts else { return true }
        return attempt <= maxAttempts
    }
}

/// Owns one ssh process and its state, restarting it when — and only when — restarting
/// could plausibly help.
public actor TunnelSupervisor {
    public nonisolated let spec: TunnelSpec

    public private(set) var status: TunnelStatus = TunnelStatus(state: .idle)

    public var state: TunnelState { status.state }

    private let launcher: any SSHLauncher
    private let policy: RetryPolicy
    private let interactive: Bool
    private var machine: TunnelStateMachine
    private var current: (any SSHProcess)?
    private var supervision: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<TunnelStatus>.Continuation] = [:]

    public init(
        spec: TunnelSpec,
        launcher: any SSHLauncher = SystemSSHLauncher(),
        policy: RetryPolicy = .default,
        interactive: Bool = true
    ) {
        self.spec = spec
        self.launcher = launcher
        self.policy = policy
        self.interactive = interactive
        self.machine = TunnelStateMachine(spec: spec)
    }

    /// Status updates for the UI. The current status is delivered immediately on subscribe.
    public func states() -> AsyncStream<TunnelStatus> {
        let (stream, continuation) = AsyncStream<TunnelStatus>.makeStream()
        let id = UUID()
        observers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// Events that only update internal bookkeeping (a recorded failure cause, say) leave
    /// the status unchanged; emitting those would make observers see spurious repeats.
    private func publish(_ newStatus: TunnelStatus) {
        guard newStatus != status else { return }
        status = newStatus
        for continuation in observers.values { continuation.yield(newStatus) }
    }

    /// Starts, or restarts after a failure.
    ///
    /// A finished run must clear `supervision`, otherwise the completed task keeps this guard
    /// true and the tunnel can never be started again — leaving a failed tunnel stuck on its
    /// error with a Start button that does nothing.
    public func start() {
        guard supervision == nil else { return }
        supervision = Task { await runLoop() }
    }

    /// True when a run is in flight. A failed tunnel is *not* running and can be started.
    public var isRunning: Bool { supervision != nil }

    public func stop() async {
        supervision?.cancel()
        supervision = nil
        await current?.terminate()
        current = nil
        machine.stopped()
        publish(machine.status)
    }

    private func runLoop() async {
        // Every exit path must release the slot so `start()` can run again.
        defer { supervision = nil }
        var attempt = 0

        while !Task.isCancelled {
            machine.started()
            publish(machine.status)

            let command = SSHCommand(spec: spec, interactive: interactive)
            let process: any SSHProcess
            do {
                process = try launcher.launch(command)
            } catch {
                publish(TunnelStatus(state: .failed(TunnelFailure(
                    kind: .sshExited,
                    message: "Could not launch ssh: \(error.localizedDescription)"
                ))))
                return
            }
            current = process

            // Drain stderr to EOF before folding in the exit status, so a failure line
            // that explains the exit is never lost to a race.
            for await line in await process.stderrLines() {
                guard let event = SSHOutputParser.event(from: line) else { continue }
                let updated = machine.apply(event)
                if updated == .connected { attempt = 0 }
                publish(machine.status)

                // We do not set ExitOnForwardFailure, so ssh will happily keep running with
                // a forward that never came up. When the failure is one of ours, end it here
                // rather than leave a tunnel that looks alive and carries nothing.
                if machine.hasFatalForwardFailure {
                    await process.terminate()
                }
            }

            let code = await process.waitUntilExit()
            current = nil

            if Task.isCancelled {
                machine.stopped()
                publish(machine.status)
                return
            }

            let exited = machine.exited(code: code)
            publish(machine.status)

            guard case .failed(let failure) = exited, failure.isRetryable else { return }

            attempt += 1
            guard policy.shouldRetry(attempt: attempt) else { return }

            machine.retrying(attempt: attempt)
            publish(machine.status)

            do {
                try await Task.sleep(for: policy.delay(forAttempt: attempt))
            } catch {
                machine.stopped()
                publish(machine.status)
                return
            }
        }
    }
}
