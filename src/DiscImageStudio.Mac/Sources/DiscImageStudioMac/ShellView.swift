import AppKit
import DiscImageStudioKit
import SwiftUI

/// Same order as the Windows sidebar, which is also the workflow order.
enum Workspace: String, CaseIterable, Identifiable {
    case home = "Home"
    case design = "Design"
    case preview = "Preview"
    case export = "Export"
    case burn = "Burn"
    case calibration = "Calibration"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .design: "paintbrush"
        case .preview: "eye"
        case .export: "square.and.arrow.up"
        case .burn: "flame"
        case .calibration: "scope"
        }
    }

    /// The step the header's Next button goes to. Calibration sits outside this flow.
    var next: Workspace? {
        switch self {
        case .design: .preview
        case .preview: .export
        case .export: .burn
        default: nil
        }
    }
}

struct ShellView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var preview: PreviewModel
    @StateObject private var burn: BurnModel
    @StateObject private var calibration: CalibrationModel

    init(preview: PreviewModel? = nil, burn: BurnModel? = nil, calibration: CalibrationModel? = nil) {
        _preview = StateObject(wrappedValue: preview ?? PreviewModel())
        _burn = StateObject(wrappedValue: burn ?? BurnModel())
        _calibration = StateObject(wrappedValue: calibration ?? CalibrationModel())
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $app.workspace) {
                Label(Workspace.home.rawValue, systemImage: Workspace.home.systemImage)
                    .tag(Workspace.home)
                if app.project != nil {
                    Section(app.project?.name ?? "Project") {
                        ForEach([Workspace.design, .preview, .export, .burn, .calibration]) { workspace in
                            Label(workspace.rawValue, systemImage: workspace.systemImage)
                                .tag(workspace)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                JobDock()
            }
            .toolbar { toolbar }
            .navigationTitle(title)
        }
        .sheet(isPresented: $app.showingNewProject) { NewProjectSheet() }
        .sheet(isPresented: $app.showingProjectSettings) { ProjectSettingsSheet() }
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .preferredColorScheme(app.theme.colorScheme)
        .background(WindowCloseGuardView(shouldClose: { app.confirmDiscardChanges() }))
    }

    private var title: String {
        guard let project = app.project else { return "Disc Image Studio" }
        return project.name + (app.isDirty ? " — Edited" : "")
    }

    @ViewBuilder private var detail: some View {
        switch app.workspace {
        case .home:
            HomeView()
        case .design:
            DesignView()
        case .preview:
            PreviewView(model: preview)
        case .export:
            ExportView()
        case .burn:
            BurnView(model: burn)
        case .calibration:
            CalibrationView(model: calibration)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if app.project != nil {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.showingProjectSettings = true
                } label: {
                    Label("Project Settings", systemImage: "slider.horizontal.3")
                }
                .help("Edit disc geometry")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await app.save() }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!app.isDirty)
            }
            if let next = app.workspace.next {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        app.workspace = next
                    } label: {
                        Label("Next: \(next.rawValue)", systemImage: "arrow.right")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
    }
}

/// Shows the running job, plus the log, along the bottom of every workspace.
struct JobDock: View {
    @EnvironmentObject private var app: AppModel
    @State private var showingLog = false

    var body: some View {
        if app.job != nil || !app.log.isEmpty {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    if let job = app.job {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.title).font(.callout.weight(.medium))
                            if let fraction = job.fraction {
                                ProgressView(value: min(max(fraction, 0), 1))
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                            Text(job.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Button("Cancel", role: .cancel) { job.cancel() }
                    } else {
                        Text(app.log.last ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    Button {
                        showingLog.toggle()
                    } label: {
                        Image(systemName: showingLog ? "chevron.down" : "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help(showingLog ? "Hide log" : "Show log")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if showingLog {
                    ScrollView {
                        Text(app.log.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 160)
                    .background(.background.secondary)
                }
            }
        }
    }
}

/// Lets the app veto closing a window with unsaved work. SwiftUI has no hook for this, so it
/// sits in front of SwiftUI's window delegate and forwards everything else on to it.
struct WindowCloseGuardView: NSViewRepresentable {
    var shouldClose: @MainActor () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window, !(window.delegate is WindowCloseGuard) else { return }
            context.coordinator.original = window.delegate
            context.coordinator.shouldClose = shouldClose
            window.delegate = context.coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
    }

    func makeCoordinator() -> WindowCloseGuard { WindowCloseGuard() }
}

final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    var shouldClose: (@MainActor () -> Bool)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated { shouldClose?() ?? true }
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

// MARK: Small shared controls

/// A number field that only commits a parsed value, so a half-typed entry never reaches the project.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit: String?
    /// Rounds what's shown, for values that come from dragging. Geometry leaves this unset,
    /// because those values must stay exact.
    var decimals: Int?

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
                if let unit {
                    // A fixed width keeps a column of these fields aligned across units.
                    Text(unit).foregroundStyle(.secondary).font(.caption)
                        .frame(width: 24, alignment: .leading)
                }
            }
        }
        .onAppear { text = display(value) }
        .onChange(of: value) { _, newValue in
            if !focused { text = display(newValue) }
        }
    }

    private func display(_ number: Double) -> String {
        guard let decimals else { return CommandBuilder.number(number) }
        let factor = pow(10, Double(decimals))
        return CommandBuilder.number((number * factor).rounded() / factor)
    }

    private func commit() {
        // Leaving a field without changing it must not replace the exact value with the
        // rounded one on show.
        if text != display(value), let parsed = Double(text.trimmingCharacters(in: .whitespaces)), parsed.isFinite {
            value = parsed
        }
        text = display(value)
    }
}

struct PathRow: View {
    let title: String
    let path: String
    var placeholder = "Not set"
    let choose: () -> Void
    var clear: (() -> Void)?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.isEmpty ? placeholder : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer(minLength: 8)
                if let clear, !path.isEmpty {
                    Button("Clear", action: clear)
                }
                Button("Choose…", action: choose)
            }
        }
    }
}

extension View {
    /// Keeps a Form to a readable width in a wide window.
    func pageWidth(_ width: CGFloat = 640) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}
