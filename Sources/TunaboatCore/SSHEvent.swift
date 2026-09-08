import Foundation

/// A meaningful line of `ssh -v` output.
///
/// Every pattern matched here was verified against the format strings in OpenSSH 10.3p1's
/// own binary (`strings /usr/bin/ssh`), not recalled — see `claude-debug/ssh-output-strings.md`.
public enum SSHEvent: Sendable, Equatable {
    /// `debug1: Authenticated to host ([1.2.3.4]:22) using "publickey".`
    case authenticated(method: String?)
    /// `debug1: Local forwarding listening on 127.0.0.1 port 9504.` — also emitted for `-D`.
    case forwardListening(port: Int)
    /// `debug1: Entering interactive session.` — forwards are up and traffic can flow.
    case interactiveSessionEntered
    /// `bind [127.0.0.1]:9504: Address already in use`
    case bindFailed(address: String?, port: Int?, reason: String)
    /// `channel_setup_fwd_listener_tcpip: cannot listen to port: 9504`
    case cannotListen(port: Int)
    /// `Could not request local forwarding.` / `Warning: Could not request remote forwarding.`
    case forwardingRequestRejected
    /// `Warning: remote port forwarding failed for listen port 4713`
    case remoteForwardFailed(port: Int)
    /// `user@host: Permission denied (publickey,password).`
    case permissionDenied(methods: String?)
    /// `Host key verification failed.`
    case hostKeyVerificationFailed
    /// `ssh: connect to host h port 22: Connection refused`
    case connectFailed(reason: String)
    /// `ssh: Could not resolve hostname h: nodename nor servname provided, or not known`
    case nameResolutionFailed(host: String)
}

/// Classifies a single line of ssh's verbose stderr. Pure, so the whole status ladder is
/// testable without spawning anything.
public enum SSHOutputParser {
    // Computed, not stored: `Regex` is not `Sendable`, so a shared static would be a
    // data race. Reconstruction is cheap relative to the handful of lines ssh emits per
    // connection, and the alternative — declaring the sharing safe — would not be true.
    private static var authenticated: Regex<(Substring, Substring)> { /Authenticated to .+ using "([^"]+)"/ }
    private static var listening: Regex<(Substring, Substring, Substring)> { /Local forwarding listening on (\S+) port (\d+)/ }
    private static var bind: Regex<(Substring, Substring, Substring, Substring)> { /^bind \[([^\]]+)\]:(\d+): (.+)$/ }
    private static var cannotListen: Regex<(Substring, Substring)> { /cannot listen to port: (\d+)/ }
    private static var remoteForward: Regex<(Substring, Substring)> { /remote port forwarding failed for listen port (\d+)/ }
    private static var denied: Regex<(Substring, Substring)> { /Permission denied \(([^)]*)\)/ }
    private static var connect: Regex<(Substring, Substring)> { /^ssh: connect to host .+ port \d+: (.+)$/ }
    private static var resolve: Regex<(Substring, Substring)> { /^ssh: Could not resolve hostname ([^:]+):/ }

    public static func event(from rawLine: String) -> SSHEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        // Ordered most-specific first: a "Could not resolve hostname" line also contains
        // text that looser patterns below would otherwise claim.
        if let m = line.firstMatch(of: resolve) {
            return .nameResolutionFailed(host: String(m.1))
        }
        if let m = line.firstMatch(of: connect) {
            return .connectFailed(reason: String(m.1))
        }
        if line.hasSuffix("Host key verification failed.") {
            return .hostKeyVerificationFailed
        }
        if let m = line.firstMatch(of: denied) {
            let methods = String(m.1)
            return .permissionDenied(methods: methods.isEmpty ? nil : methods)
        }
        if let m = line.firstMatch(of: bind) {
            return .bindFailed(address: String(m.1), port: Int(m.2), reason: String(m.3))
        }
        if let m = line.firstMatch(of: cannotListen) {
            return Int(m.1).map(SSHEvent.cannotListen)
        }
        if let m = line.firstMatch(of: remoteForward) {
            return Int(m.1).map(SSHEvent.remoteForwardFailed)
        }
        if line.contains("Could not request local forwarding.")
            || line.contains("Could not request remote forwarding.") {
            return .forwardingRequestRejected
        }
        // The signal STM keys off, and the only way a tunnel with no local listeners
        // (all -R forwards) ever reports itself up.
        if line.hasSuffix("Entering interactive session.") {
            return .interactiveSessionEntered
        }
        if let m = line.firstMatch(of: listening) {
            return Int(m.2).map(SSHEvent.forwardListening)
        }
        if let m = line.firstMatch(of: authenticated) {
            return .authenticated(method: String(m.1))
        }
        return nil
    }
}
