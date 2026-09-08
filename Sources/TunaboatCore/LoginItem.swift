import Foundation

#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Whether the app is set to start at login, as far as the system will tell us.
///
/// Deliberately not a `Bool`: `requiresApproval` is a real state the user must resolve in
/// System Settings and cannot be cleared from here, and a checkbox that silently does nothing
/// is the worst version of this feature.
public enum LoginItemStatus: Sendable, Equatable {
    /// Registered and permitted to launch.
    case enabled
    /// Not registered. Toggling on will register it.
    case disabled
    /// Registered, but the user switched it off in System Settings. Only they can undo that.
    case requiresApproval
    /// Cannot be managed at all from this process; `reason` is fit to show a user.
    case unavailable(reason: String)
}

/// Where the running app lives, which decides whether registering it is meaningful.
///
/// `SMAppService.mainApp` registers *the main bundle by its path*. That makes the answer
/// depend on how the binary was launched, not on any user setting, so it is worth naming.
public enum LoginItemLocation: Sendable, Equatable {
    /// No app bundle — `swift run TunaboatApp` runs a bare Mach-O out of `.build`.
    case unbundled
    /// A real bundle, but at a path that will not survive: a build directory is deleted by
    /// `rm -rf .build`, and launchd would then be pointing at nothing.
    case transient(path: String)
    /// A bundle somewhere durable.
    case installed
}

extension LoginItemLocation {
    /// Path components that mean "this will be rebuilt or thrown away".
    private static let ephemeralComponents: Set<String> = [".build", "DerivedData", "Xcode"]

    /// Classifies a bundle without touching the system, so it can be tested.
    public static func of(bundleURL: URL, bundleIdentifier: String?) -> LoginItemLocation {
        // A bundle identifier without a `.app` wrapper is not something launchd can start,
        // and `Bundle.main` reports the enclosing directory for a bare executable.
        guard bundleURL.pathExtension == "app", bundleIdentifier != nil else { return .unbundled }

        let components = Set(bundleURL.pathComponents)
        if !components.isDisjoint(with: Self.ephemeralComponents) {
            return .transient(path: bundleURL.path)
        }
        return .installed
    }

    /// Why registration is impossible, or `nil` when it is possible.
    public var blockingReason: String? {
        switch self {
        case .unbundled:
            "Launch at Login needs Tunaboat.app. Build it with Scripts/bundle-app.sh."
        case .transient, .installed:
            nil
        }
    }

    /// A caveat worth showing even though registration will succeed.
    public var advisory: String? {
        switch self {
        case .transient:
            "Registered from a build directory — move Tunaboat.app to /Applications, "
                + "or deleting the build will break it."
        case .unbundled, .installed:
            nil
        }
    }
}

/// The system side of the login item, behind a protocol so the surrounding logic can be
/// tested without registering anything on the developer's own machine.
public protocol LoginItemBackend: Sendable {
    func status() -> LoginItemStatus
    func register() throws
    func unregister() throws
}

/// Reads and changes whether the app starts at login.
///
/// The app registers *itself* rather than installing a separate headless agent: the menu bar
/// app is the single owner of the ssh children, and a daemon holding the same forwards would
/// collide with it over every port the app also tries to bind.
public struct LoginItem: Sendable {
    private let backend: LoginItemBackend
    public let location: LoginItemLocation

    public init(backend: LoginItemBackend, location: LoginItemLocation) {
        self.backend = backend
        self.location = location
    }

    /// The current state, with the location check taking precedence: there is no point
    /// asking the system about a bundle that does not exist.
    public var status: LoginItemStatus {
        if let reason = location.blockingReason { return .unavailable(reason: reason) }
        return backend.status()
    }

    /// Turns the login item on or off. Idempotent: setting it to what it already is does
    /// nothing rather than churning the registration.
    public func setEnabled(_ enabled: Bool) throws {
        let current = status
        guard current.isActionable else { throw LoginItemError.unmanageable(current.detail ?? "") }
        guard current.isOn != enabled else { return }
        if enabled {
            try backend.register()
        } else {
            try backend.unregister()
        }
    }

    /// Flips the current state and reports what it became.
    @discardableResult
    public func toggle() throws -> LoginItemStatus {
        try setEnabled(!status.isOn)
        return status
    }
}

public enum LoginItemError: Error, Equatable, LocalizedError {
    case unmanageable(String)

    public var errorDescription: String? {
        switch self {
        case .unmanageable(let reason): reason
        }
    }
}

// MARK: - Presentation

extension LoginItemStatus {
    /// Whether the checkbox shows a tick.
    ///
    /// `requiresApproval` reads as **on**: the app is registered, and the thing standing in
    /// the way is a system setting the user changed. Showing it unticked would invite them to
    /// click it, which cannot work.
    public var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: true
        case .disabled, .unavailable: false
        }
    }

    /// Whether toggling can achieve anything.
    public var isActionable: Bool {
        switch self {
        case .enabled, .disabled: true
        case .requiresApproval, .unavailable: false
        }
    }

    /// Whether the user has to finish the job in System Settings.
    public var needsSystemSettings: Bool { self == .requiresApproval }

    /// The explanation to show beneath the control, or `nil` when the state speaks for itself.
    public var detail: String? {
        switch self {
        case .enabled, .disabled:
            nil
        case .requiresApproval:
            "Turned off in System Settings → General → Login Items. Re-enable it there."
        case .unavailable(let reason):
            reason
        }
    }
}

// MARK: - The real backend

#if canImport(ServiceManagement)
/// `SMAppService.mainApp` — the supported way to register a login item on macOS 13+, and the
/// reason no LaunchAgent plist is written by hand. Registration shows up in System Settings →
/// General → Login Items, where the user can revoke it.
public struct SystemLoginItemBackend: LoginItemBackend {
    public init() {}

    public func status() -> LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

extension LoginItemStatus {
    /// Maps `SMAppService`'s status.
    ///
    /// **`notFound` means "off", not "broken".** Its name and Apple's documentation both
    /// suggest a missing bundle, and treating it that way disables the control permanently —
    /// but measured against a real bundle it is what `mainApp` reports before it has *ever*
    /// been registered, in every configuration tried: ad-hoc and Developer ID signed, inside
    /// and outside a build directory, launched directly and through LaunchServices. From that
    /// state `register()` succeeds and the status becomes `enabled`. Folding it in with
    /// `notRegistered` is therefore the behaviour that matches the system, and a registration
    /// that really cannot find its bundle surfaces as a thrown error instead.
    public init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered, .notFound: self = .disabled
        case .requiresApproval: self = .requiresApproval
        @unknown default:
            self = .unavailable(reason: "Unrecognised login item status (\(status.rawValue)).")
        }
    }
}

extension LoginItem {
    /// The login item for the running app bundle.
    public static func mainApp() -> LoginItem {
        LoginItem(
            backend: SystemLoginItemBackend(),
            location: .of(
                bundleURL: Bundle.main.bundleURL,
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
        )
    }
}
#endif
