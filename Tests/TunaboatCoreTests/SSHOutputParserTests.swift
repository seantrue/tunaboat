import Foundation
import Testing
@testable import TunaboatCore

/// Lines here are either captured verbatim from OpenSSH 10.3p1 on this machine, or
/// rendered from format strings found in `/usr/bin/ssh` itself.
@Suite("ssh -v output parsing")
struct SSHOutputParserTests {
    @Test("Captured verbatim: unresolvable host")
    func nameResolution() {
        let line = "ssh: Could not resolve hostname nonexistent.invalid: nodename nor servname provided, or not known"
        #expect(SSHOutputParser.event(from: line) == .nameResolutionFailed(host: "nonexistent.invalid"))
    }

    @Test("Captured verbatim: connection refused")
    func connectionRefused() {
        let line = "ssh: connect to host localhost port 1: Connection refused"
        #expect(SSHOutputParser.event(from: line) == .connectFailed(reason: "Connection refused"))
    }

    @Test("Captured verbatim: permission denied lists the methods tried")
    func permissionDenied() {
        let line = "user@localhost: Permission denied (publickey,password,keyboard-interactive)."
        #expect(SSHOutputParser.event(from: line)
                == .permissionDenied(methods: "publickey,password,keyboard-interactive"))
    }

    @Test("Captured verbatim: host key verification failure")
    func hostKey() {
        #expect(SSHOutputParser.event(from: "Host key verification failed.") == .hostKeyVerificationFailed)
    }

    @Test("Authentication success carries the method")
    func authenticated() {
        let line = #"debug1: Authenticated to appserver ([192.0.2.11]:22) using "publickey"."#
        #expect(SSHOutputParser.event(from: line) == .authenticated(method: "publickey"))
    }

    @Test("Each established listener is counted")
    func listening() {
        let line = "debug1: Local forwarding listening on 127.0.0.1 port 9504."
        #expect(SSHOutputParser.event(from: line) == .forwardListening(port: 9504))
    }

    @Test("The connected signal is the same one SSH Tunnel Manager keys off")
    func interactiveSession() {
        #expect(SSHOutputParser.event(from: "debug1: Entering interactive session.")
                == .interactiveSessionEntered)
    }

    @Test("A bind collision names the port and the reason")
    func bindFailure() {
        let line = "bind [127.0.0.1]:9504: Address already in use"
        #expect(SSHOutputParser.event(from: line)
                == .bindFailed(address: "127.0.0.1", port: 9504, reason: "Address already in use"))
    }

    @Test("Listener setup failure")
    func cannotListen() {
        let line = "channel_setup_fwd_listener_tcpip: cannot listen to port: 9504"
        #expect(SSHOutputParser.event(from: line) == .cannotListen(port: 9504))
    }

    @Test("A rejected remote forward is attributed to the server")
    func remoteForwardRejected() {
        let line = "Warning: remote port forwarding failed for listen port 4713"
        #expect(SSHOutputParser.event(from: line) == .remoteForwardFailed(port: 4713))
    }

    @Test("Ordinary debug chatter is ignored")
    func noiseIgnored() {
        let noise = [
            "debug1: Reading configuration data /Users/user/.ssh/config",
            "debug1: /etc/ssh/ssh_config line 54: Applying options for *",
            "debug1: Local version string SSH-2.0-OpenSSH_10.3",
            "",
            "   ",
        ]
        for line in noise {
            #expect(SSHOutputParser.event(from: line) == nil, "should ignore: \(line)")
        }
    }
}
