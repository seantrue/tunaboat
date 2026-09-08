import ArgumentParser
import Foundation
import os
import TunaboatCore

@main
struct Tunaboat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tunaboat",
        abstract: "Manage SSH tunnels.",
        subcommands: [List.self, Show.self, Up.self, Import.self]
    )
}

struct ConfigOption: ParsableArguments {
    @Option(name: .customLong("config"), help: "Path to tunnels.json.")
    var path: String?

    var store: ConfigStore {
        ConfigStore(url: path.map { URL(fileURLWithPath: $0) })
    }
}

extension Tunaboat {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List configured tunnels.")

        @OptionGroup var config: ConfigOption

        func run() throws {
            let specs = try config.store.load()
            guard !specs.isEmpty else {
                print("No tunnels configured. Try: tunaboat import")
                return
            }
            for spec in specs {
                let forwards = spec.forwards.map(\.argumentValue).joined(separator: ", ")
                print("\(spec.name)  \(spec.destination)  [\(spec.forwards.count)] \(forwards)")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the ssh command a tunnel would run."
        )

        @Argument(help: "Tunnel name.") var name: String
        @OptionGroup var config: ConfigOption

        func run() throws {
            let specs = try config.store.load()
            guard let spec = specs.first(where: { $0.name == name }) else {
                throw ValidationError("No tunnel named '\(name)'.")
            }
            print(SSHCommand(spec: spec).displayCommand)
        }
    }

    /// Runs a tunnel in the foreground, printing each state change. Ctrl-C stops it.
    struct Up: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Bring up a tunnel and report its status until interrupted."
        )

        @Argument(help: "Tunnel name.") var name: String

        @Option(help: "Give up after this many reconnect attempts (default: keep trying).")
        var maxAttempts: Int?

        @OptionGroup var config: ConfigOption

        /// Terminates the ssh child before exiting, on either signal.
        private static func installStopHandlers(
            for supervisor: TunnelSupervisor
        ) -> [DispatchSourceSignal] {
            // Both signals can arrive (a shell kill plus a timeout, say); shut down once.
            let stopping = OSAllocatedUnfairLock(initialState: false)
            return [SIGINT, SIGTERM].map { sig in
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    let alreadyStopping = stopping.withLock { was -> Bool in
                        defer { was = true }
                        return was
                    }
                    guard !alreadyStopping else { return }
                    Task {
                        await supervisor.stop()
                        FileHandle.standardError.write(Data("stopped\n".utf8))
                        Foundation.exit(0)
                    }
                }
                source.resume()
                return source
            }
        }

        func run() async throws {
            let specs = try config.store.load()
            guard let spec = specs.first(where: { $0.name == name }) else {
                throw ValidationError("No tunnel named '\(name)'.")
            }

            let supervisor = TunnelSupervisor(
                spec: spec,
                policy: RetryPolicy(maxAttempts: maxAttempts)
            )
            // Without this, SIGTERM/SIGINT kills Tunaboat and leaves the ssh child running,
            // orphaned and still holding every forwarded port. Observed for real.
            let stopSignals = Self.installStopHandlers(for: supervisor)
            defer { stopSignals.forEach { $0.cancel() } }

            let states = await supervisor.states()
            await supervisor.start()

            var reportedWarnings: Set<String> = []
            var lastState: TunnelState?
            for await status in states {
                // A status change can be warnings-only; don't reprint an unchanged state.
                if status.state != lastState {
                    FileHandle.standardError.write(Data("\(spec.name): \(status.state.summary)\n".utf8))
                    lastState = status.state
                }
                for warning in status.warnings where reportedWarnings.insert(warning).inserted {
                    FileHandle.standardError.write(Data("\(spec.name): warning: \(warning)\n".utf8))
                }
                if case .failed(let failure) = status.state, !failure.isRetryable {
                    throw ExitCode.failure
                }
            }
        }
    }

    struct Import: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import connections from tynsoe's SSH Tunnel Manager."
        )

        @Option(name: .long, help: "Path to org.tynsoe.sshtunnelmanager.plist.")
        var from: String?

        @Flag(name: .long, help: "Print what would be imported without writing.")
        var dryRun = false

        @OptionGroup var config: ConfigOption

        func run() throws {
            let imported = try STMImporter.importConnections(
                from: from.map { URL(fileURLWithPath: $0) }
            )
            guard !imported.isEmpty else {
                print("No connections found.")
                return
            }

            for spec in imported {
                print("\(spec.name)  (\(spec.destination))")
                for forward in spec.forwards {
                    print("    \(forward.kind.rawValue) \(forward.argumentValue)")
                }
                for warning in spec.importWarnings {
                    print("    ! \(warning)")
                }
                print("    $ \(SSHCommand(spec: spec).displayCommand)")
            }

            if dryRun {
                print("\n(dry run — nothing written)")
                return
            }

            let store = config.store
            let existing = try store.load()
            let existingNames = Set(existing.map(\.name))
            let new = imported.filter { !existingNames.contains($0.name) }
            let skipped = imported.count - new.count

            try store.save(existing + new)
            print("\nImported \(new.count) tunnel(s) to \(store.url.path)."
                  + (skipped > 0 ? " Skipped \(skipped) already present by name." : ""))
        }
    }
}
