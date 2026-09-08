import SwiftUI
import TunaboatCore

/// The editor window: tunnel list on the left, detail on the right.
struct TunnelEditorView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = model.selection, let spec = model.binding(for: id) {
                TunnelDetailView(model: model, spec: spec, id: id)
            } else {
                ContentUnavailableView(
                    "No Tunnel Selected",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Select a tunnel, or add one with +.")
                )
            }
        }
        .toolbar {
            // Configuration is written only here. Nothing auto-saves: a keystroke in a port
            // field would otherwise restart a live tunnel on every character.
            ToolbarItem(placement: .status) {
                if model.isDirty {
                    Label("Unsaved changes", systemImage: "pencil.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!model.isDirty)
                .keyboardShortcut("s", modifiers: .command)
                .help("Write changes to \(model.configPath)")
            }
        }
        .navigationTitle("Tunaboat")
    }

    private var sidebar: some View {
        // Driven by `model.items` (derived from the specs being edited), never by the live
        // supervisors — see AppModel.items.
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(item.indicator.color)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(item.name)
                            if item.hasWarnings {
                                // The dot stays green — the tunnel is up — so the warning
                                // needs its own mark.
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                    .help(item.warnings.joined(separator: "\n"))
                            }
                        }
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if item.isNew {
                        Spacer(minLength: 0)
                        Text("unsaved")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(item.id)
                .contextMenu {
                    Button("Duplicate") { model.duplicate(item.id) }
                    Button("Delete", role: .destructive) { model.delete(item.id) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.addTunnel() } label: { Image(systemName: "plus") }
                    .help("Add a tunnel")
                Button {
                    if let id = model.selection { model.delete(id) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(model.selection == nil)
                .help("Remove the selected tunnel")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }
}

/// The right-hand pane. A separate type so it can be rendered and reasoned about alone.
struct TunnelDetailView: View {
    @Bindable var model: AppModel
    @Binding var spec: TunnelSpec
    let id: UUID

    /// Wide enough for a fully qualified hostname, short enough not to dominate the pane.
    private static let fieldWidth: CGFloat = 220

    private var conflicts: Set<Int> {
        PortConflicts.conflictingPorts(for: spec, among: model.specs)
    }

    var body: some View {
        ScrollView { content }
        .safeAreaInset(edge: .top) {
            TunnelControlBar(row: model.runtimeRow(for: id))
        }
    }

    /// Internal rather than private so development tooling can render the pane without a
    /// ScrollView, which does not lay out offscreen.
    var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            connectionAndOptions
            // Above the forwards list, not below it: that list changes height as forwards are
            // added and removed, and anything under it moves every time.
            CommandPreview(spec: spec)
            forwardsSection
        }
        .padding(20)
    }

    /// Connection on the left, options beside it. Options are short and connection is four
    /// rows tall, so stacking them wasted the space to the right of the fields.
    private var connectionAndOptions: some View {
        HStack(alignment: .top, spacing: 28) {
            // Only the connection column is fixed: without it the HStack compresses the Grid
            // until its "Name"/"Host" labels wrap to one letter per line. Options must stay
            // flexible, or `ViewThatFits` sees unbounded width, always picks the wide row, and
            // pushes the whole pane past its edge.
            connectionSection.fixedSize()
            optionsSection
            Spacer(minLength: 0)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Connection")
            // Fields are sized to what they hold. Stretching them to the pane edge made a
            // hostname look like a paragraph field and left the form unbalanced.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("Name", text: $spec.name)
                        .frame(width: Self.fieldWidth)
                }
                GridRow {
                    Text("Host").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("hostname or ~/.ssh/config alias", text: $spec.host)
                            .frame(width: Self.fieldWidth)
                        // Beside the host, because that is what every note is about.
                        noteIcons
                    }
                }
                GridRow {
                    Text("User").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("leave empty to use ssh_config", text: Binding(
                        get: { spec.user ?? "" },
                        set: { spec.user = $0.isEmpty ? nil : $0 }
                    ))
                    .frame(width: Self.fieldWidth)
                }
                GridRow {
                    Text("Port").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("22", value: Binding(
                        get: { spec.port },
                        set: { spec.port = ($0 == 22 || $0 == 0) ? nil : $0 }
                    ), format: .number.grouping(.never))
                    .frame(width: 70)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var forwardsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Forwards")
            if spec.forwards.isEmpty {
                Text("No forwards. A tunnel with no forwards carries nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($spec.forwards) { $forward in
                ForwardRow(
                    forward: $forward,
                    conflicted: forward.kind != .remote && conflicts.contains(forward.listenPort),
                    onDelete: { model.removeForward(forward.id, from: id) }
                )
            }
            Button {
                model.addForward(to: id)
            } label: {
                Label("Add Forward", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Options")
            // Side by side: three short labels read faster than a stacked column, and the
            // full explanation lives in hover text rather than in a long label.
            // Beside the connection fields there is rarely room for one row, so this takes
            // the row when it fits and a column when it does not, rather than compressing the
            // labels into wrapped stacks. `fixedSize` keeps either arrangement from wrapping.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) { optionToggles }
                VStack(alignment: .leading, spacing: 4) { optionToggles }
            }
            .toggleStyle(.checkbox)
            .modifier(LayoutProbe(label: "options"))
        }
    }

    @ViewBuilder
    private var optionToggles: some View {
        Toggle("Connect at launch", isOn: $spec.autoConnect)
            .help("Start this tunnel automatically when Tunaboat launches.")
            .fixedSize()
        Toggle("Compression", isOn: $spec.compression)
            .help("Pass -C to ssh. Helps on slow links, costs CPU on fast ones.")
            .fixedSize()
        Toggle("All interfaces", isOn: $spec.listenOnAllInterfaces)
            .help("GatewayPorts=yes — bind forwards on every interface rather than loopback "
                  + "only, so other machines can reach them.")
            .fixedSize()
    }

    @ViewBuilder
    private var noteIcons: some View {
        let live = model.runtimeRow(for: id)?.warnings ?? []
        ForEach(live, id: \.self) { warning in
            NoteIcon(text: warning, icon: "exclamationmark.triangle.fill", tint: .orange)
        }
        ForEach(spec.importWarnings, id: \.self) { note in
            NoteIcon(text: note, icon: "info.circle.fill", tint: .secondary)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A note shown as an icon, keeping a long import warning from dominating the pane.
///
/// Click as well as hover: a bare `Image` is a poor hover target — small, and with no filled
/// area to hit — and a tooltip that does not appear leaves the note unreadable. The button
/// gives it a real hit area and a popover that does not depend on tooltips working at all.
private struct NoteIcon: View {
    let text: String
    let icon: String
    let tint: Color

    @State private var isShowingNote = false

    var body: some View {
        Button {
            isShowingNote.toggle()
        } label: {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(text)
        .popover(isPresented: $isShowingNote, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}

/// Start/stop plus the live state, pinned above the detail pane.
///
/// `row` is optional: a tunnel that has been added or duplicated has no supervisor until the
/// configuration is saved, and there is nothing to start.
private struct TunnelControlBar: View {
    let row: TunnelRow?

    var body: some View {
        HStack(spacing: 10) {
            if let row {
                TunnelControlBarContents(row: row)
            } else {
                Button("Start") {}.buttonStyle(.borderedProminent).disabled(true)
                Text("Save to start this tunnel")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct TunnelControlBarContents: View {
    @Bindable var row: TunnelRow

    var body: some View {
        Button(row.isActive ? "Stop" : "Start") { row.toggle() }
            .buttonStyle(.borderedProminent)
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(row.indicator)
        Text(row.state.summary).font(.callout)
    }
}

private struct ForwardRow: View {
    @Binding var forward: Forward
    let conflicted: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $forward.kind) {
                Text("Local").tag(ForwardKind.local)
                Text("Remote").tag(ForwardKind.remote)
                Text("SOCKS").tag(ForwardKind.dynamic)
            }
            .labelsHidden()
            .frame(width: 92)

            TextField("port", value: $forward.listenPort, format: .number.grouping(.never))
                .frame(width: 70)
                .foregroundStyle(conflicted ? Color.red : Color.primary)

            if forward.kind != .dynamic {
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("host", text: $forward.destinationHost).frame(width: 92)
                Text(":").foregroundStyle(.secondary)
                TextField("port", value: $forward.destinationPort, format: .number.grouping(.never))
                    .frame(width: 70)
            } else {
                Text("SOCKS proxy").font(.caption).foregroundStyle(.secondary)
            }

            if conflicted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help("Another forward already claims this local port")
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this forward")

            Spacer(minLength: 0)
        }
        .textFieldStyle(.roundedBorder)
    }
}

/// The exact command Tunaboat will run. Makes the app auditable, and lets the user paste it into
/// a terminal when something is wrong — the single best affordance STM lacks.
///
/// Collapsed by default: it is a diagnostic, wanted occasionally, and expanded it dominates
/// the pane. Copy stays reachable without expanding.
struct CommandPreview: View {
    let spec: TunnelSpec

    @State private var isExpanded = false

    private var command: String { SSHCommand(spec: spec).displayCommand }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                        SectionHeader("Command")
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide the ssh command" : "Show the ssh command Tunaboat will run")

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Copy the command to the clipboard")
            }

            if isExpanded {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25))
                    )
                    .transition(.opacity)
            }
        }
    }
}
