import Foundation
import Testing
@testable import TunaboatCore

@Suite("Local port conflicts")
struct PortConflictTests {
    private func spec(_ name: String, _ forwards: [Forward]) -> TunnelSpec {
        TunnelSpec(name: name, host: "h", forwards: forwards)
    }

    @Test("Two tunnels claiming the same local port conflict")
    func acrossTunnels() {
        let specs = [
            spec("a", [Forward(kind: .local, listenPort: 9504, destinationPort: 5901)]),
            spec("b", [Forward(kind: .local, listenPort: 9504, destinationPort: 80)]),
        ]
        let conflicts = PortConflicts.find(in: specs)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].port == 9504)
        #expect(conflicts[0].tunnelNames == ["a", "b"])
    }

    @Test("A tunnel claiming one port twice conflicts with itself")
    func withinOneTunnel() {
        let specs = [spec("a", [
            Forward(kind: .local, listenPort: 9504, destinationPort: 5901),
            Forward(kind: .local, listenPort: 9504, destinationPort: 80),
        ])]
        let conflicts = PortConflicts.find(in: specs)
        #expect(conflicts.count == 1)
        #expect(conflicts[0].message.contains("more than once"))
    }

    @Test("A remote listen port lives on the server and cannot collide locally")
    func remoteForwardsDoNotCollide() {
        let specs = [
            spec("a", [Forward(kind: .remote, listenPort: 4713, destinationPort: 4713)]),
            spec("b", [Forward(kind: .remote, listenPort: 4713, destinationPort: 4713)]),
        ]
        #expect(PortConflicts.find(in: specs).isEmpty)
    }

    @Test("A dynamic forward binds locally and does collide")
    func dynamicCollides() {
        let specs = [
            spec("a", [Forward(kind: .dynamic, listenPort: 1080)]),
            spec("b", [Forward(kind: .local, listenPort: 1080, destinationPort: 80)]),
        ]
        #expect(PortConflicts.find(in: specs).count == 1)
    }

    @Test("Distinct ports do not conflict")
    func noFalsePositives() {
        let specs = [
            spec("a", [Forward(kind: .local, listenPort: 9504, destinationPort: 5901)]),
            spec("b", [Forward(kind: .local, listenPort: 8204, destinationPort: 80)]),
        ]
        #expect(PortConflicts.find(in: specs).isEmpty)
    }

    @Test("Conflicting ports can be narrowed to one tunnel for highlighting")
    func perSpecHighlighting() {
        let a = spec("a", [
            Forward(kind: .local, listenPort: 9504, destinationPort: 5901),
            Forward(kind: .local, listenPort: 7000, destinationPort: 70),
        ])
        let b = spec("b", [Forward(kind: .local, listenPort: 9504, destinationPort: 80)])
        #expect(PortConflicts.conflictingPorts(for: a, among: [a, b]) == [9504])
    }
}
