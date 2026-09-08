import Foundation

/// Imports connections from tynsoe's *SSH Tunnel Manager* (bundle id
/// `org.tynsoe.sshtunnelmanager`), whose settings live in a single preferences plist.
///
/// The schema was recovered from a real 2.2.7 preferences file and from selector names
/// in the app binary. Everything it stores that Tunaboat does not model is reported as a
/// warning on the imported spec rather than dropped in silence.
public enum STMImporter {
    public static let bundleIdentifier = "org.tynsoe.sshtunnelmanager"

    public enum ImportError: Error, CustomStringConvertible {
        case fileNotFound(URL)
        case unreadable(URL, underlying: String)
        case notADictionary(URL)
        case noTunnelsKey(URL)

        public var description: String {
            switch self {
            case .fileNotFound(let url):
                "No SSH Tunnel Manager preferences at \(url.path)"
            case .unreadable(let url, let underlying):
                "Could not read \(url.path): \(underlying)"
            case .notADictionary(let url):
                "\(url.path) is not a property list dictionary"
            case .noTunnelsKey(let url):
                "\(url.path) has no 'tunnels' array — nothing to import"
            }
        }
    }

    /// Default location of the preferences file for the current user.
    public static func defaultPreferencesURL(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        home
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    /// Reads and converts every connection in the given preferences plist.
    public static func importConnections(from url: URL? = nil) throws -> [TunnelSpec] {
        let url = url ?? defaultPreferencesURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(url, underlying: error.localizedDescription)
        }
        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw ImportError.unreadable(url, underlying: error.localizedDescription)
        }
        guard let root = plist as? [String: Any] else {
            throw ImportError.notADictionary(url)
        }
        guard let connections = root["tunnels"] as? [[String: Any]] else {
            throw ImportError.noTunnelsKey(url)
        }
        return connections.map(spec(from:))
    }

    /// Converts one STM connection dictionary. Exposed so tests can drive it with
    /// fixtures rather than the user's real preferences.
    public static func spec(from dict: [String: Any]) -> TunnelSpec {
        var warnings: [String] = []

        let host = dict["connHost"] as? String ?? ""
        let name = (dict["connName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host

        let rawUser = dict["connUser"] as? String
        let user = (rawUser?.isEmpty == false) ? rawUser : nil

        // STM always writes a port. 22 means "default", and recording it explicitly would
        // override a Port set for this host in ~/.ssh/config.
        let rawPort = dict["connPort"] as? Int
        let port = (rawPort == 22 || rawPort == 0) ? nil : rawPort

        var forwards = (dict["tunnels"] as? [[String: Any]] ?? []).map(forward(from:))

        // STM's SOCKS proxy is a separate checkbox; Tunaboat models it as a dynamic forward.
        if dict["socks4"] as? Bool == true {
            let socksPort = dict["socks4port"] as? Int ?? 1080
            forwards.append(Forward(kind: .dynamic, listenPort: socksPort))
            warnings.append(
                "SOCKS proxy on port \(socksPort) imported as a dynamic (-D) forward; "
                + "ssh provides SOCKS5, not the SOCKS4 the original setting named."
            )
        }

        if dict["ignoreKeyWarning"] as? Bool == true {
            warnings.append(
                "Original connection set 'ignore key warning' (StrictHostKeyChecking=no), "
                + "which disables host-key verification. Not carried over — verify the host key instead."
            )
        }
        if let cipher = dict["encryption"] as? String, !cipher.isEmpty, cipher != "default" {
            warnings.append(
                "Original connection pinned the '\(cipher)' cipher. Not carried over; "
                + "modern OpenSSH negotiates a stronger default and may not support it at all."
            )
        }
        if dict["v1"] as? Bool == true {
            warnings.append("Original connection used SSH protocol 1, which OpenSSH has removed. Ignored.")
        }
        if dict["connAuth"] as? Bool == true {
            warnings.append(
                "Original connection used STM's password Authenticator. Tunaboat relies on ssh-agent "
                + "and the Keychain; add the key with 'ssh-add --apple-use-keychain'."
            )
        }

        let link = (dict["openLinkOnConnect"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return TunnelSpec(
            name: name,
            host: host,
            user: user,
            port: port,
            forwards: forwards,
            autoConnect: dict["autoConnect"] as? Bool ?? false,
            compression: dict["compression"] as? Bool ?? false,
            listenOnAllInterfaces: dict["connRemote"] as? Bool ?? false,
            openURLOnConnect: link.flatMap(URL.init(string:)),
            importWarnings: warnings
        )
    }

    /// STM stores `leftPort` as the listening side and `rightPort`/`host` as the
    /// destination, for both directions. `tunnelType` is 0 for local, 1 for remote.
    private static func forward(from dict: [String: Any]) -> Forward {
        let isRemote = (dict["tunnelType"] as? Int ?? 0) == 1
        let listenIP = (dict["listenIP"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Forward(
            kind: isRemote ? .remote : .local,
            listenAddress: listenIP,
            listenPort: dict["leftPort"] as? Int ?? 0,
            destinationHost: (dict["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "localhost",
            destinationPort: dict["rightPort"] as? Int ?? 0
        )
    }
}
