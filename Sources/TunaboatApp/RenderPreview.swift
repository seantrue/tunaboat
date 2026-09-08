// TEMPORARY development scaffolding — renders the editor to a PNG for visual inspection.
// Not part of the shipping app; removed after use.
import AppKit
import SwiftUI
import TunaboatCore

/// Every probe here ends the process early, and `exit()` runs neither
/// `applicationWillTerminate` nor the SIGTERM handler — so an `exit(0)` on its own leaves the
/// ssh children re-parented to launchd, still holding every forwarded port. Constructing
/// `AppModel` is enough to start them, because "Connect at launch" fires from `reload()`.
/// Four orphans were produced this way before this existed. Probes exit through here.
@MainActor
private func probeExit(_ code: Int32) -> Never {
    SSHProcessRegistry.terminateAll()
    exit(code)
}

enum RenderPreview {
    @MainActor
    static func renderIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["TUNABOAT_RENDER_PNG"] else { return }
        let model = AppModel()
        guard let id = model.selection, let spec = model.binding(for: id) else {
            FileHandle.standardError.write(Data("no tunnel to render\n".utf8)); probeExit(1)
        }
        let view = TunnelDetailView(model: model, spec: spec, id: id)
            .content
            .frame(width: Double(ProcessInfo.processInfo.environment["TUNABOAT_RENDER_WIDTH"] ?? "") ?? 660)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8)); probeExit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
        probeExit(0)
    }
}

/// TEMPORARY development scaffolding — reports what the login item looks like from *inside*
/// the running bundle, which is the one thing the unit tests cannot reach: they exercise
/// `LoginItemLocation.of` against synthetic paths, not against a real `Bundle.main`.
///
/// Strictly read-only. It never registers anything, so running it cannot leave a login item
/// behind on the machine that ran it.
enum LoginItemProbe {
    @MainActor
    static func reportIfRequested() {
        let mode = ProcessInfo.processInfo.environment["TUNABOAT_LOGIN_PROBE"]
        guard mode == "1" || mode == "roundtrip" else { return }
        let item = LoginItem.mainApp()
        let lines = [
            "bundleURL:  \(Bundle.main.bundleURL.path)",
            "bundleID:   \(Bundle.main.bundleIdentifier ?? "<none>")",
            "location:   \(item.location)",
            "status:     \(item.status)",
            "blocking:   \(item.location.blockingReason ?? "<none>")",
            "advisory:   \(item.location.advisory ?? "<none>")",
        ]
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))

        // `roundtrip` registers and then immediately unregisters, to establish whether a
        // status can actually be acted on. Self-cleaning: it must leave no login item behind.
        if mode == "roundtrip" {
            var log: [String] = []
            do {
                try SystemLoginItemBackend().register()
                log.append("register:   ok -> \(SystemLoginItemBackend().status())")
            } catch {
                log.append("register:   FAILED \(error)")
            }
            do {
                try SystemLoginItemBackend().unregister()
                log.append("unregister: ok -> \(SystemLoginItemBackend().status())")
            } catch {
                log.append("unregister: FAILED \(error)")
            }
            FileHandle.standardError.write(Data((log.joined(separator: "\n") + "\n").utf8))
        }
        probeExit(0)
    }
}

/// TEMPORARY development scaffolding — reports a view's measured size from the *live* window.
///
/// `ImageRenderer` is not a faithful oracle for layout: it refuses `ScrollView` and
/// `NavigationSplitView` outright, so a render agreeing with the intended design does not
/// prove the real window agrees. This measures what actually happened on screen.
struct LayoutProbe: ViewModifier {
    let label: String

    func body(content: Content) -> some View {
        guard ProcessInfo.processInfo.environment["TUNABOAT_LAYOUT_PROBE"] == "1" else {
            return AnyView(content)
        }
        return AnyView(content.background(
            GeometryReader { proxy in
                Color.clear.onAppear {
                    let size = proxy.size
                    FileHandle.standardError.write(Data(
                        "LAYOUT \(label): \(Int(size.width))x\(Int(size.height))\n".utf8
                    ))
                }
            }
        ))
    }
}
