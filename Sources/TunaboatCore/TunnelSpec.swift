import Foundation

/// What kind of port forward `ssh` should set up.
public enum ForwardKind: String, Codable, Sendable, CaseIterable {
    /// `-L` — listen locally, forward to `destination` as seen from the server.
    case local
    /// `-R` — listen on the server, forward to `destination` as seen from this machine.
    case remote
    /// `-D` — local SOCKS proxy; `destination` is unused.
    case dynamic
}

/// One `-L` / `-R` / `-D` forward within a connection.
public struct Forward: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: ForwardKind
    /// Bind address for the listening side. `nil` lets ssh apply its own default
    /// (localhost for `-L`/`-D`; `GatewayPorts` decides for `-R`).
    public var listenAddress: String?
    public var listenPort: Int
    /// Host as resolved by the *other* end of the connection. Ignored for `.dynamic`.
    public var destinationHost: String
    public var destinationPort: Int

    public init(
        id: UUID = UUID(),
        kind: ForwardKind = .local,
        listenAddress: String? = nil,
        listenPort: Int,
        destinationHost: String = "localhost",
        destinationPort: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.listenAddress = listenAddress
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    /// The value passed to ssh's `-L` / `-R` / `-D`.
    public var argumentValue: String {
        let bind = listenAddress.map { "\($0):" } ?? ""
        switch kind {
        case .dynamic:
            return "\(bind)\(listenPort)"
        case .local, .remote:
            return "\(bind)\(listenPort):\(destinationHost):\(destinationPort)"
        }
    }

    public var flag: String {
        switch kind {
        case .local: "-L"
        case .remote: "-R"
        case .dynamic: "-D"
        }
    }
}

/// Liveness probing, expressed as ssh's own keepalive options.
public struct KeepAlive: Codable, Sendable, Equatable {
    public var intervalSeconds: Int
    public var maxMissed: Int

    public init(intervalSeconds: Int = 15, maxMissed: Int = 3) {
        self.intervalSeconds = intervalSeconds
        self.maxMissed = maxMissed
    }

    public static let `default` = KeepAlive()
}

/// One ssh connection and every forward carried over it.
///
/// `host` is passed to ssh verbatim so a `Host` alias from `~/.ssh/config` keeps working;
/// `user` and `port` stay `nil` unless the user explicitly overrode them, so we never
/// shadow what the alias already specifies.
public struct TunnelSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var user: String?
    public var port: Int?
    public var forwards: [Forward]

    public var autoConnect: Bool
    public var compression: Bool
    public var keepAlive: KeepAlive
    /// Bind forwards on all interfaces rather than loopback (`-o GatewayPorts=yes`).
    public var listenOnAllInterfaces: Bool
    /// Opened once the connection reports itself up.
    public var openURLOnConnect: URL?

    /// Notes surfaced in the UI — currently populated by import, for settings we
    /// deliberately dropped rather than silently translated.
    public var importWarnings: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        user: String? = nil,
        port: Int? = nil,
        forwards: [Forward] = [],
        autoConnect: Bool = false,
        compression: Bool = false,
        keepAlive: KeepAlive = .default,
        listenOnAllInterfaces: Bool = false,
        openURLOnConnect: URL? = nil,
        importWarnings: [String] = []
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.forwards = forwards
        self.autoConnect = autoConnect
        self.compression = compression
        self.keepAlive = keepAlive
        self.listenOnAllInterfaces = listenOnAllInterfaces
        self.openURLOnConnect = openURLOnConnect
        self.importWarnings = importWarnings
    }

    /// `user@host`, or just `host` when no explicit user was set.
    public var destination: String {
        user.map { "\($0)@\(host)" } ?? host
    }
}

extension TunnelSpec {
    /// A name not already taken by `existing`, suffixing a counter when needed.
    ///
    /// Names are how the CLI addresses a tunnel (`tunaboat up <name>`), so duplicates would make
    /// one of them unreachable.
    public static func uniqueName(base: String, among existing: some Sequence<String>) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// A copy with fresh identifiers and a non-colliding name, for "Duplicate".
    public func duplicated(among existing: [TunnelSpec]) -> TunnelSpec {
        var copy = self
        copy.id = UUID()
        copy.name = Self.uniqueName(base: name, among: existing.map(\.name))
        copy.forwards = forwards.map { forward in
            var f = forward
            f.id = UUID()
            return f
        }
        return copy
    }
}
