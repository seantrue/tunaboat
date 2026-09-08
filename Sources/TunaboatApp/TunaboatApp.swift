import AppKit
import SwiftUI
import TunaboatCore

/// Menu bar front end plus an editor window. Deliberately thin — parsing, state derivation
/// and supervision all live in TunaboatCore, the only target `swift test` can reach.
@main
struct TunaboatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            menuContents
        } label: {
            // The label renders at launch, unlike the menu contents, so it is where a
            // first-run action belongs.
            Image(systemName: model.aggregateSymbol)
                .onAppear(perform: openEditorOnFirstRun)
                // The user can revoke the login item in System Settings without telling us,
                // so re-read it whenever the app comes forward rather than trusting the
                // value cached at launch.
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.didBecomeActiveNotification
                    )
                ) { _ in model.refreshLoginItemStatus() }
        }
        .menuBarExtraStyle(.menu)

        Window("Tunaboat", id: Self.editorWindowID) {
            TunnelEditorView(model: model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 900, height: 560)
    }

    /// Registers the app itself as a login item (`SMAppService.mainApp`), rather than
    /// installing a headless LaunchAgent: the app is the single owner of the ssh children,
    /// and a daemon holding the same forwards would fight it for every port.
    @ViewBuilder
    private var launchAtLogin: some View {
        if model.loginItemStatus.needsSystemSettings {
            // Registered but switched off by the user; only System Settings can undo that,
            // so offer the trip there instead of a checkbox that cannot work.
            Button("Launch at Login — Open Settings…") { model.openLoginItemsSettings() }
        } else {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { model.loginItemStatus.isOn },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            .disabled(!model.loginItemStatus.isActionable)
        }

        if let detail = model.loginItemDetail {
            Text(detail).font(.caption)
        }
    }

    static let editorWindowID = "tunnel-editor"

    /// A menu bar app with nothing configured shows an icon and no window, which reads as
    /// "it didn't launch". Open the editor so there is something to act on.
    private func openEditorOnFirstRun() {
        let forced = ProcessInfo.processInfo.environment["TUNABOAT_OPEN_EDITOR"] == "1"
        guard forced || model.items.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: Self.editorWindowID)
    }

    @ViewBuilder
    private var menuContents: some View {
        if let error = model.loadError {
            Text("Config error: \(error)")
        } else if model.items.isEmpty {
            Text("No tunnels configured")
            Text("Run: tunaboat import").font(.caption)
        } else {
            ForEach(model.items) { item in
                Button {
                    model.toggle(item.id)
                } label: {
                    // The menu shows state, and for a failure the reason, inline — a red dot
                    // you have to open Console to explain is the thing that makes tunnel
                    // managers annoying.
                    Label {
                        // The state is in the text as well as the dot: menu icons can be
                        // tinted by the system, and text cannot be misread.
                        Text("\(item.hasWarnings ? "⚠︎ " : "")\(item.name) — \(item.detail)")
                    } icon: {
                        Image(nsImage: item.indicator.menuDot())
                            .renderingMode(.original)
                    }
                }
                .disabled(item.isNew)
                ForEach(item.warnings, id: \.self) { warning in
                    Text("⚠︎ \(warning)").font(.caption)
                }
            }
        }

        Divider()

        // Surfaced in the menu too, so unsaved work is visible without opening the editor.
        if model.isDirty {
            Button("Save Configuration") { model.save() }
        }

        Button("Edit Tunnels…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: Self.editorWindowID)
        }
        .keyboardShortcut(",")

        Button("Reload Configuration") { model.reload() }

        Divider()

        launchAtLogin

        Divider()

        Button("Quit Tunaboat") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// A menu bar utility, so no Dock icon by default.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LoginItemProbe.reportIfRequested()
        RenderPreview.renderIfRequested()
        installTerminationHandlers()
    }

    /// Quitting must take the ssh children with it. Without this they are re-parented to
    /// launchd and keep holding every forwarded port, so the next launch fails to bind a
    /// port that nothing visible is using.
    func applicationWillTerminate(_ notification: Notification) {
        SSHProcessRegistry.terminateAll()
    }

    /// `applicationWillTerminate` does not run for a bare SIGTERM (`pkill`, a stop from a
    /// script), which is how the orphans in development were created.
    private func installTerminationHandlers() {
        signalSources = [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                SSHProcessRegistry.terminateAll()
                NSApp.terminate(nil)
            }
            source.resume()
            return source
        }
    }
}
