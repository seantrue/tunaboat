import Foundation
import Testing
@testable import TunaboatCore

@Suite("Tunnel list presentation")
struct TunnelListPresenterTests {
    private func spec(_ name: String, forwards: Int = 1) -> TunnelSpec {
        TunnelSpec(
            name: name, host: name,
            forwards: (0..<forwards).map {
                Forward(kind: .local, listenPort: 9000 + $0, destinationPort: 80)
            }
        )
    }

    @Test("A deleted tunnel disappears even while its supervisor is still alive")
    func deletedTunnelIsNotListed() {
        // Reported bug: deleting `appserver` removed it from the configuration but left it in
        // the sidebar, because the list was built from the live supervisors — which are only
        // rebuilt on save — instead of from the specs being edited.
        let home = spec("home")
        let appsrv = spec("appserver")
        let statuses: [UUID: TunnelStatus] = [
            home.id: TunnelStatus(state: .connected),
            appsrv.id: TunnelStatus(state: .connected),
        ]

        let items = TunnelListPresenter.items(specs: [home], statuses: statuses)

        #expect(items.count == 1)
        #expect(items.map(\.name) == ["home"])
        #expect(!items.contains { $0.id == appsrv.id })
    }

    @Test("A newly added tunnel appears immediately, before any save")
    func addedTunnelIsListed() {
        // The same root cause in the other direction: a tunnel with no supervisor yet.
        let existing = spec("home")
        let added = spec("New Tunnel")
        let items = TunnelListPresenter.items(
            specs: [existing, added],
            statuses: [existing.id: TunnelStatus(state: .connected)]
        )

        #expect(items.count == 2)
        #expect(items[1].name == "New Tunnel")
        #expect(items[1].isNew)
        #expect(items[1].indicator == .idle)
    }

    @Test("Order follows the configuration, not the supervisors")
    func orderFollowsSpecs() {
        let a = spec("a"), b = spec("b"), c = spec("c")
        let items = TunnelListPresenter.items(
            specs: [c, a, b],
            statuses: [a.id: TunnelStatus(state: .connected)]
        )
        #expect(items.map(\.name) == ["c", "a", "b"])
    }

    @Test("Every row states its connection state, including an idle one")
    func detailAlwaysLeadsWithState() {
        // Reported: the menu showed no connection state at all on first open, because an
        // idle tunnel displayed only its forward count.
        let one = spec("one", forwards: 1)
        let many = spec("many", forwards: 7)
        let empty = TunnelSpec(name: "empty", host: "h")

        #expect(TunnelListPresenter.detail(for: one, state: .idle) == "Idle · 1 forward")
        #expect(TunnelListPresenter.detail(for: many, state: .idle) == "Idle · 7 forwards")
        #expect(TunnelListPresenter.detail(for: empty, state: .idle) == "Idle · no forwards")

        let failure = TunnelFailure(kind: .portInUse, message: "Port 9504: Address already in use")
        #expect(TunnelListPresenter.detail(for: one, state: .failed(failure))
                == "Port 9504: Address already in use")
    }

    @Test("stateText carries the state on its own, for a menu that shows nothing else")
    func stateTextIsAlwaysPresent() {
        let s = spec("y")
        let idle = TunnelListPresenter.items(specs: [s], statuses: [:])[0]
        let up = TunnelListPresenter.items(
            specs: [s], statuses: [s.id: TunnelStatus(state: .connected)]
        )[0]
        let failed = TunnelListPresenter.items(
            specs: [s],
            statuses: [s.id: TunnelStatus(state: .failed(
                TunnelFailure(kind: .authentication, message: "Authentication failed")))]
        )[0]

        #expect(idle.stateText == "Idle")
        #expect(up.stateText == "Connected")
        #expect(failed.stateText == "Authentication failed")
        #expect(!idle.stateText.isEmpty && !up.stateText.isEmpty && !failed.stateText.isEmpty)
    }

    @Test("A warning badge is separate from the dot, so a warned tunnel still reads connected")
    func warningBadgeIsSeparateFromIndicator() {
        // Yellow means idle, so a connected-but-warned tunnel must not be recoloured; the
        // warning is carried by `hasWarnings` instead.
        let s = spec("y")
        let warned = TunnelListPresenter.items(
            specs: [s],
            statuses: [s.id: TunnelStatus(state: .connected, warnings: ["config forward failed"])]
        )[0]
        let idle = TunnelListPresenter.items(specs: [s], statuses: [:])[0]

        #expect(warned.hasWarnings)
        #expect(!idle.hasWarnings)
        #expect(warned.indicator != idle.indicator)
    }

    @Test("A tunnel that is up but carrying a warning is distinguishable from a clean one")
    func warningIndicator() {
        let s = spec("y")
        let clean = TunnelListPresenter.items(
            specs: [s], statuses: [s.id: TunnelStatus(state: .connected)]
        )
        let warned = TunnelListPresenter.items(
            specs: [s],
            statuses: [s.id: TunnelStatus(state: .connected, warnings: ["config forward failed"])]
        )
        #expect(clean[0].indicator == .connected)
        #expect(warned[0].indicator == .connectedWithWarnings)
        #expect(warned[0].warnings.count == 1)
    }

    @Test("An unnamed tunnel still has something to click")
    func unnamedTunnel() {
        let items = TunnelListPresenter.items(
            specs: [TunnelSpec(name: "", host: "")], statuses: [:]
        )
        #expect(items[0].name == "Untitled")
    }

    @Test("The menu bar icon reflects the worst state present")
    func aggregate() {
        func items(_ indicators: [TunnelIndicator]) -> [TunnelListItem] {
            indicators.map {
                TunnelListItem(id: UUID(), name: "x", stateText: "", detail: "", indicator: $0)
            }
        }
        #expect(TunnelListPresenter.aggregateIndicator(for: items([])) == .idle)
        #expect(TunnelListPresenter.aggregateIndicator(for: items([.connected, .failed])) == .failed)
        #expect(TunnelListPresenter.aggregateIndicator(for: items([.connected, .working])) == .working)
        #expect(TunnelListPresenter.aggregateIndicator(
            for: items([.connected, .connectedWithWarnings])) == .connectedWithWarnings)
        #expect(TunnelListPresenter.aggregateIndicator(for: items([.idle, .connected])) == .connected)
    }
}
