import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import TunaboatCore

/// One tunnel in the menu: its spec, its supervisor, and the latest status.
@MainActor
@Observable
final class TunnelRow: Identifiable {
    private(set) var spec: TunnelSpec
    private(set) var state: TunnelState = .idle
    /// Non-fatal problems — typically a forward inherited from ~/.ssh/config that failed.
    private(set) var warnings: [String] = []

    private let supervisor: TunnelSupervisor
    private var observation: Task<Void, Never>?

    /// Stored rather than read from `spec`, which is main-actor isolated while `Identifiable`
    /// requires `id` to be reachable from anywhere.
    nonisolated let id: UUID

    init(spec: TunnelSpec) {
        self.id = spec.id
        self.spec = spec
        self.supervisor = TunnelSupervisor(spec: spec)
        observation = Task { [supervisor] in
            for await status in await supervisor.states() {
                self.state = status.state
                self.warnings = status.warnings
            }
        }
    }

    func toggle() {
        Task { [supervisor] in
            if await supervisor.state.isActive {
                await supervisor.stop()
            } else {
                await supervisor.start()
            }
        }
    }

    /// Stops ssh and ends observation. Called when a row is replaced by an edited spec.
    func shutdown() {
        observation?.cancel()
        observation = nil
        Task { [supervisor] in await supervisor.stop() }
    }

    var isActive: Bool { state.isActive }

    /// Colour carries the coarse state; the label carries the detail. Routed through
    /// `TunnelIndicator` so the editor and the menu cannot drift apart.
    var indicator: Color {
        TunnelIndicator(state: state, hasWarnings: !warnings.isEmpty).color
    }

    /// Shown beside the name. A failed tunnel says *why* here, so diagnosing never requires
    /// opening Console.
    var detail: String {
        switch state {
        case .idle: "\(spec.forwards.count) forward\(spec.forwards.count == 1 ? "" : "s")"
        default: state.summary
        }
    }
}

/// Shared state for both the menu bar and the editor window.
@MainActor
@Observable
final class AppModel {
    private(set) var specs: [TunnelSpec] = []
    private(set) var rows: [TunnelRow] = []
    private(set) var loadError: String?

    /// Editor selection, kept here so reopening the window restores it.
    var selection: UUID?
    /// The configuration as it currently exists on disk. `isDirty` is derived by comparing
    /// against it, so the indicator cannot claim unsaved changes that are already written —
    /// which matters now that deleting saves on its own.
    private var savedSpecs: [TunnelSpec] = []

    var isDirty: Bool { specs != savedSpecs }

    private let store: ConfigStore

    // MARK: - Launch at login

    private let loginItem: LoginItem
    /// Cached rather than read live: the menu is rebuilt often, and this crosses into launchd.
    /// Refreshed at launch, after any toggle, and whenever the app is activated — which is how
    /// a change the user made in System Settings gets noticed.
    private(set) var loginItemStatus: LoginItemStatus = .disabled
    /// Set only when a registration attempt actually failed.
    private(set) var loginItemError: String?

    init(store: ConfigStore = ConfigStore(), loginItem: LoginItem = .mainApp()) {
        self.store = store
        self.loginItem = loginItem
        reload()
        refreshLoginItemStatus()
    }

    var configPath: String { store.url.path }

    var conflicts: [PortConflict] { PortConflicts.find(in: specs) }

    /// What the sidebar and menu render.
    ///
    /// Derived from `specs`, never from `rows`: supervisors are rebuilt only on save, so a
    /// list driven by them keeps showing deleted tunnels and misses newly added ones.
    var items: [TunnelListItem] {
        TunnelListPresenter.items(specs: specs, statuses: statuses)
    }

    private var statuses: [UUID: TunnelStatus] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, TunnelStatus(state: $0.state, warnings: $0.warnings)) })
    }

    /// The supervisor for a tunnel, if it has one. A tunnel added but not yet saved has none.
    func runtimeRow(for id: UUID) -> TunnelRow? { rows.first { $0.id == id } }

    func toggle(_ id: UUID) { rows.first { $0.id == id }?.toggle() }

    func refreshLoginItemStatus() {
        loginItemStatus = loginItem.status
    }

    /// The caveat to show beside the control: a failed attempt first, then whatever the
    /// status itself explains, then the location warning.
    var loginItemDetail: String? {
        loginItemError ?? loginItemStatus.detail ?? loginItem.location.advisory
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Could not \(enabled ? "enable" : "disable") Launch at Login: "
                + error.localizedDescription
        }
        refreshLoginItemStatus()
    }

    /// The only route out of `requiresApproval`: the app cannot re-enable itself once the
    /// user has switched it off there.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func reload() {
        do {
            let loaded = try store.load()
            loadError = nil
            savedSpecs = loaded
            apply(loaded, rebuildRows: true)
            // Driven from here rather than from a view's `onAppear`: the menu bar label's
            // appearance is not a reliable launch event, and hanging auto-connect off it made
            // "Connect at launch" fire only sometimes.
            startAutoConnectTunnels()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func save() {
        do {
            try store.save(specs)
            loadError = nil
            savedSpecs = specs
            reconcileRows()
        } catch {
            loadError = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: - Editing

    func addTunnel() {
        var spec = TunnelSpec(
            name: TunnelSpec.uniqueName(base: "New Tunnel", among: specs.map(\.name)),
            host: ""
        )
        spec.forwards = [Forward(kind: .local, listenPort: 8080, destinationPort: 80)]
        specs.append(spec)
        selection = spec.id
    }

    func duplicate(_ id: UUID) {
        guard let source = specs.first(where: { $0.id == id }) else { return }
        let copy = source.duplicated(among: specs)
        specs.append(copy)
        selection = copy.id
    }

    /// Deleting is immediate: it stops the tunnel and writes the removal to disk.
    ///
    /// Requiring a save to finish a deletion left an ssh process running for a tunnel that
    /// had already vanished from every list. `ConfigStore.removeTunnel` rewrites the file
    /// from disk rather than from `specs`, so any other edits in flight stay unsaved.
    func delete(_ id: UUID) {
        specs.removeAll { $0.id == id }

        if let row = rows.first(where: { $0.id == id }) {
            row.shutdown()
            rows.removeAll { $0.id == id }
        }

        do {
            savedSpecs = try store.removeTunnel(id: id)
            loadError = nil
        } catch {
            loadError = "Could not remove tunnel: \(error.localizedDescription)"
        }

        if selection == id { selection = specs.first?.id }
    }

    func addForward(to id: UUID) {
        guard let index = specs.firstIndex(where: { $0.id == id }) else { return }
        specs[index].forwards.append(
            Forward(kind: .local, listenPort: 0, destinationPort: 0)
        )
    }

    func removeForward(_ forwardID: UUID, from id: UUID) {
        guard let index = specs.firstIndex(where: { $0.id == id }) else { return }
        specs[index].forwards.removeAll { $0.id == forwardID }
    }

    func binding(for id: UUID) -> Binding<TunnelSpec>? {
        guard let index = specs.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.specs[index] ?? TunnelSpec(name: "", host: "") },
            set: { [weak self] newValue in
                guard let self, self.specs.indices.contains(index) else { return }
                self.specs[index] = newValue
            }
        )
    }

    // MARK: - Row lifecycle

    private func apply(_ newSpecs: [TunnelSpec], rebuildRows: Bool) {
        specs = newSpecs
        if rebuildRows {
            rows.forEach { $0.shutdown() }
            rows = newSpecs.map(TunnelRow.init(spec:))
        }
        if selection == nil || !newSpecs.contains(where: { $0.id == selection }) {
            selection = newSpecs.first?.id
        }
    }

    /// Rebuilds only the rows whose spec actually changed, so saving an unrelated edit does
    /// not tear down a live tunnel.
    private func reconcileRows() {
        var updated: [TunnelRow] = []
        for spec in specs {
            if let existing = rows.first(where: { $0.id == spec.id }), existing.spec == spec {
                updated.append(existing)
            } else {
                let previous = rows.first { $0.id == spec.id }
                let wasRunning = previous?.isActive ?? false
                previous?.shutdown()
                let replacement = TunnelRow(spec: spec)
                // Saving an edit to a running tunnel should reconnect it with the new
                // settings, not silently leave it down.
                if wasRunning { replacement.toggle() }
                updated.append(replacement)
            }
        }
        for removed in rows where !specs.contains(where: { $0.id == removed.id }) {
            removed.shutdown()
        }
        rows = updated
    }

    // MARK: - Menu presentation

    func startAutoConnectTunnels() {
        for row in rows where row.spec.autoConnect && !row.isActive {
            row.toggle()
        }
    }

    /// Drives the menu bar icon: worst state wins, because a failed tunnel is the thing the
    /// user needs to notice.
    var aggregateSymbol: String {
        switch TunnelListPresenter.aggregateIndicator(for: items) {
        case .failed: "exclamationmark.triangle.fill"
        case .working: "arrow.left.arrow.right.circle"
        case .connected, .connectedWithWarnings: "arrow.left.arrow.right.circle.fill"
        case .idle: "arrow.left.arrow.right"
        }
    }
}

extension TunnelIndicator {
    /// The one place `TunaboatCore`'s framework-free indicator becomes a colour.
    ///
    /// Green connected, red failed, yellow idle. A tunnel that is up but carrying a warning
    /// stays **green** — it is connected, and yellow now means idle — with the warning shown
    /// by a separate badge rather than by recolouring the dot. Orange is reserved for the
    /// transient states so they read as distinct from all three.
    var nsColor: NSColor {
        switch self {
        case .idle: .systemYellow
        case .working: .systemOrange
        case .connected, .connectedWithWarnings: .systemGreen
        case .failed: .systemRed
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// A **non-template** dot for use in menus.
    ///
    /// SwiftUI renders `Image(systemName:)` inside a menu as a template image and tints it
    /// with the menu's own colour, discarding `foregroundStyle` — which is why the dropdown
    /// showed no colour at all. A bitmap with `isTemplate = false` keeps it.
    func menuDot(diameter: CGFloat = 10) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
