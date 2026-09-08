import Foundation
import ServiceManagement
import Testing
import os
@testable import TunaboatCore

/// A stand-in for `SMAppService`, so none of this registers anything on the machine running
/// the tests. Sendable without `@unchecked`: the mutable state lives inside the lock.
private final class FakeBackend: LoginItemBackend, Sendable {
    struct Failure: Error, Equatable {}

    private struct State: Sendable {
        var status: LoginItemStatus
        var registrations = 0
        var unregistrations = 0
        var failing = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(status: LoginItemStatus = .disabled, failing: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(status: status, failing: failing))
    }

    func status() -> LoginItemStatus { state.withLock { $0.status } }

    func register() throws {
        try state.withLock {
            if $0.failing { throw Failure() }
            $0.registrations += 1
            $0.status = .enabled
        }
    }

    func unregister() throws {
        try state.withLock {
            if $0.failing { throw Failure() }
            $0.unregistrations += 1
            $0.status = .disabled
        }
    }

    var registrations: Int { state.withLock { $0.registrations } }
    var unregistrations: Int { state.withLock { $0.unregistrations } }
}

@Suite("Login item location")
struct LoginItemLocationTests {
    @Test("A bare executable is unbundled and cannot be registered")
    func bareExecutable() {
        // What `swift run TunaboatApp` gives us: Bundle.main is the enclosing directory.
        let location = LoginItemLocation.of(
            bundleURL: URL(fileURLWithPath: "/Users/x/tunaboat/.build/arm64-apple-macosx/debug"),
            bundleIdentifier: nil
        )
        #expect(location == .unbundled)
        #expect(location.blockingReason != nil)
    }

    @Test("A .app without a bundle identifier is still unbundled")
    func appWithoutIdentifier() {
        #expect(
            LoginItemLocation.of(
                bundleURL: URL(fileURLWithPath: "/Applications/Tunaboat.app"),
                bundleIdentifier: nil
            ) == .unbundled
        )
    }

    @Test("An installed bundle registers with no caveat")
    func installed() {
        let location = LoginItemLocation.of(
            bundleURL: URL(fileURLWithPath: "/Applications/Tunaboat.app"),
            bundleIdentifier: "dev.impressionist.tunaboat"
        )
        #expect(location == .installed)
        #expect(location.blockingReason == nil)
        #expect(location.advisory == nil)
    }

    @Test("A bundle inside .build registers, but says it will not survive a clean")
    func buildDirectoryIsTransient() {
        let path = "/Users/x/tunaboat/.build/Tunaboat.app"
        let location = LoginItemLocation.of(
            bundleURL: URL(fileURLWithPath: path),
            bundleIdentifier: "dev.impressionist.tunaboat"
        )
        #expect(location == .transient(path: path))
        // Registration is possible — this is only a warning.
        #expect(location.blockingReason == nil)
        #expect(location.advisory != nil)
    }

    @Test("A DerivedData bundle is transient too")
    func derivedDataIsTransient() {
        let location = LoginItemLocation.of(
            bundleURL: URL(fileURLWithPath: "/Users/x/Library/Developer/Xcode/DerivedData/T-abc/Build/Products/Debug/Tunaboat.app"),
            bundleIdentifier: "dev.impressionist.tunaboat"
        )
        #expect(location.advisory != nil)
        #expect(location.blockingReason == nil)
    }
}

@Suite("Login item registration")
struct LoginItemTests {
    private func item(
        _ backend: FakeBackend,
        location: LoginItemLocation = .installed
    ) -> LoginItem {
        LoginItem(backend: backend, location: location)
    }

    @Test("Enabling registers exactly once")
    func enable() throws {
        let backend = FakeBackend(status: .disabled)
        let login = item(backend)

        try login.setEnabled(true)

        #expect(backend.registrations == 1)
        #expect(login.status == .enabled)
    }

    @Test("Setting the state it is already in does not re-register")
    func idempotent() throws {
        let backend = FakeBackend(status: .enabled)
        let login = item(backend)

        try login.setEnabled(true)

        #expect(backend.registrations == 0)
        #expect(backend.unregistrations == 0)
    }

    @Test("Toggling flips the registration and reports the new state")
    func toggling() throws {
        let backend = FakeBackend(status: .disabled)
        let login = item(backend)

        #expect(try login.toggle() == .enabled)
        #expect(try login.toggle() == .disabled)
        #expect(backend.registrations == 1)
        #expect(backend.unregistrations == 1)
    }

    /// The location check must win over the backend: registering a path that does not exist
    /// would leave launchd pointing at nothing.
    @Test("An unbundled app reports unavailable without consulting the system")
    func unbundledIsUnavailable() {
        let backend = FakeBackend(status: .enabled)
        let login = item(backend, location: .unbundled)

        guard case .unavailable = login.status else {
            Issue.record("expected .unavailable, got \(login.status)")
            return
        }
        #expect(throws: LoginItemError.self) { try login.setEnabled(true) }
        #expect(backend.registrations == 0)
    }

    /// `requiresApproval` means the user switched it off in System Settings. The app cannot
    /// undo that, and must not pretend otherwise by trying.
    @Test("Approval-required cannot be toggled from the app")
    func requiresApprovalIsNotActionable() {
        let backend = FakeBackend(status: .requiresApproval)
        let login = item(backend)

        #expect(login.status == .requiresApproval)
        #expect(login.status.needsSystemSettings)
        #expect(!login.status.isActionable)
        // Shown ticked: it *is* registered, and offering an untick invites a click that
        // cannot do anything.
        #expect(login.status.isOn)
        #expect(throws: LoginItemError.self) { try login.setEnabled(false) }
        #expect(backend.unregistrations == 0)
    }

    @Test("A failing registration propagates rather than reporting success")
    func failurePropagates() {
        let backend = FakeBackend(status: .disabled, failing: true)
        let login = item(backend)

        #expect(throws: FakeBackend.Failure.self) { try login.setEnabled(true) }
        #expect(login.status == .disabled)
    }

    @Test("Only the states that speak for themselves have no detail text")
    func detailText() {
        #expect(LoginItemStatus.enabled.detail == nil)
        #expect(LoginItemStatus.disabled.detail == nil)
        #expect(LoginItemStatus.requiresApproval.detail != nil)
        #expect(LoginItemStatus.unavailable(reason: "no bundle").detail == "no bundle")
    }

    @Test("Only enabled and approval-required read as on")
    func onSemantics() {
        #expect(LoginItemStatus.enabled.isOn)
        #expect(LoginItemStatus.requiresApproval.isOn)
        #expect(!LoginItemStatus.disabled.isOn)
        #expect(!LoginItemStatus.unavailable(reason: "x").isOn)
    }
}

@Suite("SMAppService status mapping")
struct LoginItemStatusMappingTests {
    /// Pinned because getting this wrong is invisible: mapping `notFound` to "unavailable"
    /// compiles, passes every other test, and leaves the toggle permanently disabled on a
    /// machine where the app has never been registered — which is every fresh install.
    ///
    /// Measured against a real bundle: `mainApp.status` is `notFound` before the first
    /// registration, and `register()` succeeds from there.
    @Test("A never-registered app reads as off, not as broken")
    func notFoundIsOff() {
        #expect(LoginItemStatus(.notFound) == .disabled)
        #expect(LoginItemStatus(.notFound).isActionable)
        #expect(!LoginItemStatus(.notFound).isOn)
    }

    @Test("The remaining statuses map straight across")
    func directMappings() {
        #expect(LoginItemStatus(.enabled) == .enabled)
        #expect(LoginItemStatus(.notRegistered) == .disabled)
        #expect(LoginItemStatus(.requiresApproval) == .requiresApproval)
    }
}
