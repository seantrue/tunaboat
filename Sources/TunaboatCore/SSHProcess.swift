import Foundation
import os

/// Every live ssh child, so they can be killed synchronously when the app is going away.
///
/// A GUI app that is quit or killed does not take its subprocesses with it: the children are
/// re-parented to launchd and go on holding every forwarded port, so the next launch fails
/// with "Address already in use" on a port nothing visible is using. Observed for real.
public enum SSHProcessRegistry {
    private static let pids = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    static func register(_ pid: pid_t) {
        pids.withLock { $0.insert(pid) }
    }

    static func unregister(_ pid: pid_t) {
        pids.withLock { $0.remove(pid) }
    }

    public static var livePIDs: [pid_t] {
        pids.withLock { Array($0).sorted() }
    }

    /// Synchronous by design: it must be callable from `applicationWillTerminate`, which
    /// cannot await anything.
    @discardableResult
    public static func terminateAll() -> Int {
        let doomed = pids.withLock { current -> Set<pid_t> in
            defer { current.removeAll() }
            return current
        }
        for pid in doomed { kill(pid, SIGTERM) }
        return doomed.count
    }
}

/// A running `ssh` process, abstracted so the supervisor can be driven by a fake in tests
/// without spawning anything.
public protocol SSHProcess: Sendable {
    /// Verbose stderr, one line at a time. Finishes at EOF.
    func stderrLines() async -> AsyncStream<String>
    /// Exit status. Multiple callers may await this.
    func waitUntilExit() async -> Int32
    func terminate() async
}

public protocol SSHLauncher: Sendable {
    func launch(_ command: SSHCommand) throws -> any SSHProcess
}

/// Spawns the real `/usr/bin/ssh`.
public struct SystemSSHLauncher: SSHLauncher {
    public init() {}

    public func launch(_ command: SSHCommand) throws -> any SSHProcess {
        try SystemSSHProcess(command: command)
    }
}

/// An actor rather than a lock-guarded class: `Process` and its termination handler are
/// touched from several threads, and actor isolation is the honest way to say so.
public actor SystemSSHProcess: SSHProcess {
    private let process: Process
    private let stream: AsyncStream<String>
    private let readTask: Task<Void, Never>
    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []

    public init(command: SSHCommand) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SSHCommand.executable)
        process.arguments = command.arguments

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        // ssh must never inherit a terminal it could prompt on; a GUI askpass is the
        // supported way to ask for a passphrase.
        process.standardInput = FileHandle.nullDevice

        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.process = process
        self.stream = stream
        self.readTask = Task.detached {
            do {
                for try await line in errPipe.fileHandleForReading.bytes.lines {
                    continuation.yield(line)
                }
            } catch {
                // Pipe closed underneath us; EOF is the only outcome that matters.
            }
            continuation.finish()
        }

        try process.run()
        SSHProcessRegistry.register(process.processIdentifier)
        Task { await self.watchForExit() }
    }

    private func watchForExit() async {
        // Process.waitUntilExit blocks, so keep it off the actor's executor.
        let process = self.process
        let code = await Task.detached(priority: .utility) { () -> Int32 in
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        recordExit(code)
    }

    private func recordExit(_ code: Int32) {
        guard exitCode == nil else { return }
        exitCode = code
        SSHProcessRegistry.unregister(process.processIdentifier)
        for waiter in exitWaiters { waiter.resume(returning: code) }
        exitWaiters.removeAll()
    }

    public func stderrLines() -> AsyncStream<String> { stream }

    public func waitUntilExit() async -> Int32 {
        if let exitCode { return exitCode }
        return await withCheckedContinuation { continuation in
            if let exitCode {
                continuation.resume(returning: exitCode)
            } else {
                exitWaiters.append(continuation)
            }
        }
    }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    deinit { readTask.cancel() }
}
