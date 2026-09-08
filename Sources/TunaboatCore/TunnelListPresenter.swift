import Foundation

/// How a tunnel should be indicated in a list. Kept free of any colour so `TunaboatCore` stays
/// UI-framework-free; the front end maps these to colours.
public enum TunnelIndicator: Sendable, Equatable {
    case idle
    /// Connecting, authenticating, partially forwarded, or reconnecting.
    case working
    case connected
    /// Up, but something non-fatal is worth showing — a forward from `~/.ssh/config` failed.
    case connectedWithWarnings
    case failed

    public init(state: TunnelState, hasWarnings: Bool) {
        switch state {
        case .idle: self = .idle
        case .connecting, .authenticated, .forwarding, .reconnecting: self = .working
        case .connected: self = hasWarnings ? .connectedWithWarnings : .connected
        case .failed: self = .failed
        }
    }
}

/// One row of the tunnel list, ready to render.
public struct TunnelListItem: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// The connection state, always — "Idle", "Connecting…", "Connected", "2 of 3 ports
    /// forwarded", or the failure reason.
    public var stateText: String
    /// Secondary line. Always begins with the state, so a list row states the connection
    /// state even when nothing is running; the forward count follows when idle.
    public var detail: String
    public var indicator: TunnelIndicator
    public var warnings: [String]
    /// True when this tunnel has no supervisor yet — added or duplicated but not saved.
    public var isNew: Bool

    /// Whether to show a warning badge. Separate from ``indicator`` because a tunnel that is
    /// up but carrying a warning still shows a connected (green) dot.
    public var hasWarnings: Bool { !warnings.isEmpty }

    public init(
        id: UUID, name: String, stateText: String, detail: String,
        indicator: TunnelIndicator, warnings: [String] = [], isNew: Bool = false
    ) {
        self.id = id
        self.name = name
        self.stateText = stateText
        self.detail = detail
        self.indicator = indicator
        self.warnings = warnings
        self.isNew = isNew
    }
}

/// Builds the tunnel list from the specs being edited, plus whatever runtime status exists.
///
/// **The list is derived from `specs`, never from the set of live supervisors.** Supervisors
/// are rebuilt only on save, so a list driven by them shows tunnels that have been deleted
/// and hides ones just added.
public enum TunnelListPresenter {
    public static func items(
        specs: [TunnelSpec],
        statuses: [UUID: TunnelStatus]
    ) -> [TunnelListItem] {
        specs.map { spec in
            let status = statuses[spec.id]
            let state = status?.state ?? .idle
            let warnings = status?.warnings ?? []
            return TunnelListItem(
                id: spec.id,
                name: spec.name.isEmpty ? "Untitled" : spec.name,
                stateText: state.summary,
                detail: detail(for: spec, state: state),
                indicator: TunnelIndicator(state: state, hasWarnings: !warnings.isEmpty),
                warnings: warnings,
                isNew: status == nil
            )
        }
    }

    static func detail(for spec: TunnelSpec, state: TunnelState) -> String {
        // Lead with the state unconditionally. Showing only the forward count while idle
        // left the menu with no connection state at all until something was started.
        guard state == .idle else { return state.summary }
        let count = spec.forwards.count
        guard count > 0 else { return "Idle · no forwards" }
        return "Idle · \(count) forward\(count == 1 ? "" : "s")"
    }

    /// Worst state wins: a failed tunnel is the thing the user needs to notice.
    public static func aggregateIndicator(for items: [TunnelListItem]) -> TunnelIndicator {
        if items.contains(where: { $0.indicator == .failed }) { return .failed }
        if items.contains(where: { $0.indicator == .working }) { return .working }
        if items.contains(where: { $0.indicator == .connectedWithWarnings }) {
            return .connectedWithWarnings
        }
        if items.contains(where: { $0.indicator == .connected }) { return .connected }
        return .idle
    }
}
