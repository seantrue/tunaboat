import Foundation

/// Reads and writes the tunnel list shared by the CLI and the menu bar app.
///
/// Plain JSON at a hand-editable path on purpose: the user should be able to diff it,
/// keep it in a dotfiles repo, and edit it without either front end running.
public struct ConfigStore: Sendable {
    public var url: URL

    /// Where the configuration lived before the project was renamed from `tmon`.
    ///
    /// Read when the current path has no file yet, so an existing installation keeps its
    /// tunnels. The old file is never written to or deleted: the first save writes the new
    /// path and leaves the old one as a fallback the user can remove when they are ready.
    public var legacyURL: URL?

    private static func configBase(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".config")
    }

    public static func defaultURL(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        configBase(home: home).appendingPathComponent("tunaboat/tunnels.json")
    }

    public static func legacyDefaultURL(
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        configBase(home: home).appendingPathComponent("tmon/tunnels.json")
    }

    public init(url: URL? = nil, legacyURL: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        // Only consult the legacy path for the default location. A caller that names an
        // explicit file means that file.
        self.legacyURL = url == nil ? (legacyURL ?? Self.legacyDefaultURL()) : legacyURL
    }

    /// The file `load()` will actually read, or `nil` when neither exists.
    public var effectiveURL: URL? {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) { return legacyURL }
        return nil
    }

    public func load() throws -> [TunnelSpec] {
        guard let source = effectiveURL else { return [] }
        let decoder = JSONDecoder()
        return try decoder.decode([TunnelSpec].self, from: Data(contentsOf: source))
    }

    /// Removes one tunnel from the persisted configuration and returns what remains.
    ///
    /// Reads and rewrites the file rather than persisting the caller's in-memory list, so a
    /// deletion commits *only* the deletion — any other edits the user has in flight stay
    /// unsaved rather than being written as a side effect.
    @discardableResult
    public func removeTunnel(id: UUID) throws -> [TunnelSpec] {
        let current = try load()
        let remaining = current.filter { $0.id != id }
        // A tunnel added but never saved is not on disk; nothing to rewrite.
        if remaining.count != current.count {
            try save(remaining)
        }
        return remaining
    }

    public func save(_ specs: [TunnelSpec]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(specs).write(to: url, options: .atomic)
    }
}
