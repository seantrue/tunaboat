import Foundation

/// Two tunnels asking for the same local port, or one tunnel asking twice.
///
/// Worth catching before ssh does: a collision surfaces there as a bind failure partway
/// through connecting, and the editor can say so while the port is being typed.
public struct PortConflict: Sendable, Equatable, Identifiable {
    public var port: Int
    /// Names of the tunnels competing for it, in configuration order. A name repeats when a
    /// single tunnel declares the same port twice.
    public var tunnelNames: [String]

    public var id: Int { port }

    public init(port: Int, tunnelNames: [String]) {
        self.port = port
        self.tunnelNames = tunnelNames
    }

    public var message: String {
        let names = Set(tunnelNames)
        if names.count == 1, let name = names.first {
            return "\(name) declares port \(port) more than once"
        }
        return "Port \(port) is claimed by \(tunnelNames.joined(separator: ", "))"
    }
}

public enum PortConflicts {
    /// Local listening ports claimed more than once across the given tunnels.
    ///
    /// Only `-L` and `-D` forwards bind locally; a `-R` listen port lives on the server and
    /// cannot collide with anything here.
    public static func find(in specs: [TunnelSpec]) -> [PortConflict] {
        var claims: [Int: [String]] = [:]
        for spec in specs {
            for forward in spec.forwards where forward.kind != .remote {
                claims[forward.listenPort, default: []].append(spec.name)
            }
        }
        return claims
            .filter { $0.value.count > 1 }
            .map { PortConflict(port: $0.key, tunnelNames: $0.value) }
            .sorted { $0.port < $1.port }
    }

    /// Ports in `spec` that collide with something, for highlighting a single editor pane.
    public static func conflictingPorts(for spec: TunnelSpec, among specs: [TunnelSpec]) -> Set<Int> {
        let conflicts = find(in: specs)
        let mine = Set(spec.forwards.filter { $0.kind != .remote }.map(\.listenPort))
        return Set(conflicts.map(\.port)).intersection(mine)
    }
}
