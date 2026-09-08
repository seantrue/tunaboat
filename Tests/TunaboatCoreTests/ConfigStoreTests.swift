import Foundation
import Testing
@testable import TunaboatCore

@Suite("Configuration store")
struct ConfigStoreTests {
    /// Errors propagate deliberately: swallowing them here would hide a failing assertion.
    private func withTemporaryStore(_ body: (ConfigStore) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tunaboat-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(ConfigStore(url: dir.appendingPathComponent("tunnels.json")))
    }

    private func spec(_ name: String) -> TunnelSpec {
        TunnelSpec(name: name, host: name, forwards: [
            Forward(kind: .local, listenPort: 9000, destinationPort: 80),
        ])
    }

    @Test("An absent configuration reads as empty rather than failing")
    func missingFileIsEmpty() throws {
        try withTemporaryStore { store in
            let loaded = try store.load()
            #expect(loaded.isEmpty)
        }
    }

    @Test("Specs survive a save/load round trip")
    func roundTrip() throws {
        try withTemporaryStore { store in
            let original = [spec("home"), spec("backend")]
            try store.save(original)
            let loaded = try store.load()
            #expect(loaded == original)
        }
    }

    @Test("Removing a tunnel persists immediately, without a separate save")
    func removePersists() throws {
        try withTemporaryStore { store in
            let home = spec("home"), appsrv = spec("appserver")
            try store.save([home, appsrv])

            let remaining = try store.removeTunnel(id: appsrv.id)
            #expect(remaining.map(\.name) == ["home"])

            // Re-read from disk: the deletion must be on disk, not just in the return value.
            let onDisk = try store.load()
            #expect(onDisk.map(\.name) == ["home"])
        }
    }

    @Test("A deletion commits only the deletion, not other unsaved edits")
    func removeDoesNotCommitUnsavedEdits() throws {
        try withTemporaryStore { store in
            var home = spec("home")
            let appsrv = spec("appserver")
            try store.save([home, appsrv])

            // The user edits `home` in the editor but has not saved.
            home.host = "edited.example.test"

            try store.removeTunnel(id: appsrv.id)

            let onDisk = try store.load()
            #expect(onDisk.map(\.name) == ["home"])
            #expect(onDisk[0].host == "home", "unsaved edit must not be written by a delete")
        }
    }

    @Test("Removing a tunnel that was never saved leaves the file untouched")
    func removeUnsavedTunnel() throws {
        try withTemporaryStore { store in
            try store.save([spec("home")])
            let neverSaved = spec("scratch")

            let remaining = try store.removeTunnel(id: neverSaved.id)
            #expect(remaining.map(\.name) == ["home"])

            let onDisk = try store.load()
            #expect(onDisk.map(\.name) == ["home"])
        }
    }

    @Test("Deleting the last tunnel leaves a valid empty configuration")
    func removeLastTunnel() throws {
        try withTemporaryStore { store in
            let only = spec("only")
            try store.save([only])

            try store.removeTunnel(id: only.id)

            let onDisk = try store.load()
            #expect(onDisk.isEmpty)
        }
    }
}

/// The project was renamed from `tunaboat` to Tunaboat; an existing installation must not lose
/// its tunnels because the configuration directory changed underneath it.
@Suite("Migration from the Tunaboat configuration path")
struct ConfigMigrationTests {
    private func withTemporaryHome(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunaboat-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func store(in home: URL) -> ConfigStore {
        ConfigStore(
            url: home.appendingPathComponent(".config/tunaboat/tunnels.json"),
            legacyURL: home.appendingPathComponent(".config/tmon/tunnels.json")
        )
    }

    private func spec(_ name: String) -> TunnelSpec {
        TunnelSpec(name: name, host: name)
    }

    @Test("The default paths are ~/.config/tunaboat and, for legacy, ~/.config/tmon")
    func defaultPaths() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(ConfigStore.defaultURL(home: home).path.hasSuffix(".config/tunaboat/tunnels.json"))
        #expect(ConfigStore.legacyDefaultURL(home: home).path.hasSuffix(".config/tmon/tunnels.json"))
    }

    @Test("Tunnels written under the old name are still read")
    func readsLegacyConfig() throws {
        try withTemporaryHome { home in
            let legacy = ConfigStore(url: home.appendingPathComponent(".config/tmon/tunnels.json"))
            try legacy.save([spec("backend"), spec("home")])

            let loaded = try store(in: home).load()
            #expect(loaded.map(\.name) == ["backend", "home"])
        }
    }

    @Test("The new path wins once it exists")
    func newPathTakesPrecedence() throws {
        try withTemporaryHome { home in
            try ConfigStore(url: home.appendingPathComponent(".config/tmon/tunnels.json"))
                .save([spec("old")])
            try ConfigStore(url: home.appendingPathComponent(".config/tunaboat/tunnels.json"))
                .save([spec("new")])

            let loaded = try store(in: home).load()
            #expect(loaded.map(\.name) == ["new"])
        }
    }

    @Test("Saving migrates to the new path and leaves the old file intact")
    func savingMigrates() throws {
        try withTemporaryHome { home in
            let legacyURL = home.appendingPathComponent(".config/tmon/tunnels.json")
            try ConfigStore(url: legacyURL).save([spec("backend")])

            let migrating = store(in: home)
            let loaded = try migrating.load()
            try migrating.save(loaded)

            #expect(FileManager.default.fileExists(atPath: migrating.url.path))
            #expect(FileManager.default.fileExists(atPath: legacyURL.path),
                    "the old file is a fallback, not ours to delete")
            #expect(try ConfigStore(url: migrating.url).load().map(\.name) == ["backend"])
        }
    }

    @Test("With neither file present the configuration is empty, not an error")
    func neitherExists() throws {
        try withTemporaryHome { home in
            let loaded = try store(in: home).load()
            #expect(loaded.isEmpty)
        }
    }
}
