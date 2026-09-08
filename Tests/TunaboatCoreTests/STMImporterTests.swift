import Foundation
import Testing
@testable import TunaboatCore

/// Fixtures mirror the shape of a real `org.tynsoe.sshtunnelmanager.plist` (STM 2.2.7).
@Suite("SSH Tunnel Manager import")
struct STMImporterTests {
    /// A function rather than a stored static: `[String: Any]` is not Sendable,
    /// so a shared global would be a data race under Swift 6.
    static func multiForwardConnection() -> [String: Any] {[
        "connName": "home",
        "connHost": "home.example.test",
        "connUser": "user",
        "connPort": 4389,
        "connRemote": false,
        "autoConnect": false,
        "compression": false,
        "encryption": "3des",
        "ignoreKeyWarning": false,
        "socks4": false,
        "socks4port": 1080,
        "v1": false,
        "openLinkOnConnect": "",
        "tunnels": [
            ["host": "localhost", "leftPort": 9504, "rightPort": 5901, "tunnelType": 0],
            ["host": "localhost", "leftPort": 8204, "rightPort": 80, "tunnelType": 0],
        ],
    ]}

    @Test("Connection fields map across")
    func basicMapping() {
        let spec = STMImporter.spec(from: Self.multiForwardConnection())
        #expect(spec.name == "home")
        #expect(spec.host == "home.example.test")
        #expect(spec.user == "user")
        #expect(spec.port == 4389)
        #expect(spec.forwards.count == 2)
    }

    @Test("tunnelType 0 is local, 1 is remote")
    func tunnelTypeMapping() {
        let local = STMImporter.spec(from: ["connHost": "h", "tunnels": [
            ["host": "localhost", "leftPort": 1, "rightPort": 2, "tunnelType": 0],
        ]])
        let remote = STMImporter.spec(from: ["connHost": "h", "tunnels": [
            ["host": "localhost", "leftPort": 4713, "rightPort": 4713, "tunnelType": 1],
        ]])
        #expect(local.forwards.first?.kind == .local)
        #expect(remote.forwards.first?.kind == .remote)
    }

    @Test("Per-forward listenIP becomes the bind address")
    func listenIP() {
        let spec = STMImporter.spec(from: ["connHost": "h", "tunnels": [
            ["host": "localhost", "leftPort": 5901, "rightPort": 5901,
             "tunnelType": 0, "listenIP": "127.0.0.1"],
        ]])
        #expect(spec.forwards.first?.listenAddress == "127.0.0.1")
    }

    @Test("Port 22 is dropped so ~/.ssh/config keeps control")
    func defaultPortNotPinned() {
        let spec = STMImporter.spec(from: ["connHost": "appserver", "connPort": 22])
        #expect(spec.port == nil)
        #expect(SSHCommand(spec: spec).arguments.contains("-p") == false)
    }

    @Test("Empty connName falls back to the host")
    func nameFallback() {
        let spec = STMImporter.spec(from: ["connHost": "backend", "connName": ""])
        #expect(spec.name == "backend")
    }

    @Test("Empty connUser does not produce an '@host' destination")
    func emptyUser() {
        let spec = STMImporter.spec(from: ["connHost": "h", "connUser": ""])
        #expect(spec.user == nil)
        #expect(spec.destination == "h")
    }

    @Test("SOCKS checkbox becomes a dynamic forward, with a note about SOCKS4 vs 5")
    func socksBecomesDynamic() {
        let spec = STMImporter.spec(from: [
            "connHost": "h", "socks4": true, "socks4port": 1080,
        ])
        #expect(spec.forwards.contains { $0.kind == .dynamic && $0.listenPort == 1080 })
        #expect(spec.importWarnings.contains { $0.contains("SOCKS") })
    }

    @Test("Insecure and obsolete settings are reported, not silently carried over")
    func unsafeSettingsWarn() {
        let spec = STMImporter.spec(from: [
            "connHost": "h", "ignoreKeyWarning": true, "encryption": "3des", "v1": true,
        ])
        #expect(spec.importWarnings.count == 3)
        #expect(spec.importWarnings.contains { $0.contains("StrictHostKeyChecking") })
        // The dangerous setting must not survive into the command we actually run.
        #expect(!SSHCommand(spec: spec).displayCommand.contains("StrictHostKeyChecking=no"))
    }

    @Test("A missing preferences file is an error, not an empty import")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/Tunaboat-test/stm.plist")
        #expect(throws: STMImporter.ImportError.self) {
            _ = try STMImporter.importConnections(from: url)
        }
    }

    @Test("Round-trips through a real plist file on disk")
    func readsPlistFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tunaboat-stm-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("org.tynsoe.sshtunnelmanager.plist")
        let root: [String: Any] = ["tunnels": [Self.multiForwardConnection()]]
        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .xml, options: 0
        )
        try data.write(to: url)

        let specs = try STMImporter.importConnections(from: url)
        #expect(specs.count == 1)
        #expect(specs.first?.forwards.count == 2)
    }
}
