import Foundation
import Testing
@testable import TunaboatCore

@Suite("ssh argv construction")
struct SSHCommandTests {
    @Test("Local forward renders as -L listen:host:port")
    func localForward() {
        let spec = TunnelSpec(
            name: "home",
            host: "example.test",
            user: "user",
            forwards: [Forward(kind: .local, listenPort: 9504, destinationPort: 5901)]
        )
        let args = SSHCommand(spec: spec).arguments
        #expect(args.contains("-L"))
        #expect(args.contains("9504:localhost:5901"))
        #expect(args.last == "user@example.test")
    }

    @Test("Remote and dynamic forwards use the right flags")
    func otherForwardKinds() {
        let spec = TunnelSpec(
            name: "x",
            host: "h",
            forwards: [
                Forward(kind: .remote, listenPort: 4713, destinationPort: 4713),
                Forward(kind: .dynamic, listenPort: 1080),
            ]
        )
        let args = SSHCommand(spec: spec).arguments
        #expect(args.contains("-R"))
        #expect(args.contains("4713:localhost:4713"))
        #expect(args.contains("-D"))
        #expect(args.contains("1080"))
    }

    @Test("Bind address is prefixed onto the listening side")
    func bindAddress() {
        let forward = Forward(
            kind: .local, listenAddress: "127.0.0.1",
            listenPort: 5901, destinationPort: 5901
        )
        #expect(forward.argumentValue == "127.0.0.1:5901:localhost:5901")
    }

    @Test("ExitOnForwardFailure is off by default, and opt-in")
    func exitOnForwardFailureIsOptIn() {
        // It hands a forward inherited from ~/.ssh/config the power to kill a tunnel over a
        // port Tunaboat never configured. TunnelStateMachine attributes failures by port
        // ownership instead. See SSHCommand's note.
        let spec = TunnelSpec(name: "x", host: "h")
        #expect(!SSHCommand(spec: spec).arguments.contains("ExitOnForwardFailure=yes"))
        #expect(SSHCommand(spec: spec, exitOnForwardFailure: true)
            .arguments.contains("ExitOnForwardFailure=yes"))
    }

    @Test("Keepalives are always set so a dead network kills the process")
    func keepAliveAlwaysSet() {
        let args = SSHCommand(spec: TunnelSpec(name: "x", host: "h")).arguments
        #expect(args.contains("ServerAliveInterval=15"))
        #expect(args.contains("ServerAliveCountMax=3"))
    }

    @Test("Non-interactive runs fail fast instead of blocking on a prompt")
    func batchModeOnlyWhenNonInteractive() {
        let spec = TunnelSpec(name: "x", host: "h")
        #expect(SSHCommand(spec: spec, interactive: false).arguments.contains("BatchMode=yes"))
        #expect(!SSHCommand(spec: spec, interactive: true).arguments.contains("BatchMode=yes"))
    }

    @Test("No explicit user or port means ssh_config is left to decide")
    func aliasPassThrough() {
        let args = SSHCommand(spec: TunnelSpec(name: "appserver", host: "appserver")).arguments
        #expect(args.last == "appserver")
        #expect(!args.contains("-p"))
    }
}

@Suite("Tunnel naming")
struct TunnelNamingTests {
    @Test("An unused name is left alone")
    func passthrough() {
        #expect(TunnelSpec.uniqueName(base: "home", among: ["work"]) == "home")
    }

    @Test("A taken name gets the first free counter")
    func suffixes() {
        #expect(TunnelSpec.uniqueName(base: "home", among: ["home"]) == "home 2")
        #expect(TunnelSpec.uniqueName(base: "home", among: ["home", "home 2"]) == "home 3")
    }

    @Test("Gaps in the sequence are filled")
    func fillsGaps() {
        #expect(TunnelSpec.uniqueName(base: "home", among: ["home", "home 3"]) == "home 2")
    }

    @Test("Duplicating gives fresh ids so the original is untouched")
    func duplicateHasFreshIdentity() {
        let original = TunnelSpec(name: "home", host: "h", forwards: [
            Forward(kind: .local, listenPort: 9504, destinationPort: 5901),
        ])
        let copy = original.duplicated(among: [original])

        #expect(copy.id != original.id)
        #expect(copy.name == "home 2")
        #expect(copy.forwards[0].id != original.forwards[0].id)
        #expect(copy.forwards[0].listenPort == original.forwards[0].listenPort)
    }
}
