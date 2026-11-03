import DiscImageStudioKit
import SwiftUI
import UniformTypeIdentifiers

enum PreviewMode: String, CaseIterable, Identifiable {
    case projection = "Design projection"
    case readback = "File read-back"
    var id: String { rawValue }
}

/// Preview-only settings. They describe how to inspect a disc, not how to make one, so they
/// aren't saved in the project, the same as on Windows.
@MainActor
final class PreviewModel: ObservableObject {
    @Published var mode: PreviewMode = .projection
    @Published var measured = MeasuredGeometry(innerRadiusMm: 24, outerRadiusMm: 58)
    @Published var size = 1200
    @Published var samplesPerSector = 8
    @Published var artifactPath = ""
    @Published var image: NSImage?
    @Published var imagePath: String?
    @Published var hasFileRegion = false
    @Published var status = ""
    @Published var isRendering = false

    private var task: Task<Void, Never>?
    private var runningJob: CLIJob?
    private var loadedProjectKey: String?

    /// A freshly opened project starts neutral: measured values equal generation values, so
    /// any difference on screen comes from what the user entered.
    func sync(with app: AppModel) {
        guard let project = app.project else { return }
        let key = (app.projectURL?.path ?? project.name) + project.discFamily.rawValue
        if key != loadedProjectKey {
            loadedProjectKey = key
            resetMeasured(project)
            size = project.discFamily == .cd ? 1600 : project.discFamily == .dvd ? 1200 : 2048
            samplesPerSector = project.discFamily == .cd ? 16 : 8
            image = nil
            imagePath = nil
            artifactPath = ""
        }
        if artifactPath.isEmpty, let artifact = app.lastArtifactPath { artifactPath = artifact }
    }

    /// Starts from the geometry the file was generated with, when it recorded one.
    func useArtifact(_ path: String, app: AppModel) async {
        artifactPath = path
        if let project = app.project, let runner = app.runner,
           let info = try? await runner.json(ArtifactInfo.self, ["gui-artifact-info", "--family", project.discFamily.rawValue, "--input", path]),
           info.hasSidecar, let inner = info.innerRadiusMm, let outer = info.outerRadiusMm {
            measured = MeasuredGeometry(innerRadiusMm: inner, outerRadiusMm: outer,
                                        pitchLinear: info.pitchLinear ?? 0,
                                        pitchQuadratic: info.pitchQuadratic ?? 0,
                                        pitchCubic: info.pitchCubic ?? 0)
        }
        refresh(app: app, debounce: false)
    }

    func resetMeasured(_ project: ProjectDocument) {
        measured = MeasuredGeometry(geometry: project.geometry)
    }

    /// Generous when the disc family allows it, but bounded as the Windows page bounds it.
    private func clampedSize(_ family: DiscFamily) -> Int {
        min(max(size, family == .bd ? 64 : 256), 8192)
    }

    func refresh(app: AppModel, debounce: Bool = true) {
        task?.cancel()
        runningJob?.cancel()
        guard let settings = app.jobSettings, let runner = app.runner else { return }
        let mode = mode
        let measured = measured
        let artifact = artifactPath
        let composite = app.compositePath
        let size = clampedSize(settings.family)
        let samples = min(max(samplesPerSector, 1), 16)

        let source: String
        switch mode {
        case .projection:
            guard let composite else {
                status = "Import an image on the Design page first."
                return
            }
            source = composite
        case .readback:
            guard !artifact.isEmpty, FileManager.default.fileExists(atPath: artifact) else {
                status = artifact.isEmpty ? "Choose a generated file to read back." : "That file no longer exists."
                return
            }
            source = artifact
        }

        isRendering = true
        status = "Rendering \(size) px preview…"
        task = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled, let self else { return }
            do {
                let family = settings.family.rawValue
                let output = try app.cacheFile("\(family)-live-\(UUID().uuidString).png")
                var fileRegion = false
                switch mode {
                case .projection:
                    var plan: (start: Int64, end: Int64)?
                    if settings.hasFiles {
                        let result = try await runner.json(DrawingPlan.self, CommandBuilder.drawingPlan(settings))
                        plan = (result.start, result.end)
                    }
                    _ = try await runner.capture(CommandBuilder.projection(settings, measured: measured, sourcePath: source, outputPath: output.path, size: size, samplesPerSector: samples, drawing: plan)) { [weak self] job in
                        Task { @MainActor in self?.runningJob = job }
                    }
                    if let plan {
                        _ = try await runner.capture(CommandBuilder.overlay(settings, measured: measured, path: output.path, drawing: plan))
                        fileRegion = true
                    }
                case .readback:
                    // The file's own record wins over the project, which may have moved on
                    // since the file was made or may not be the project that made it.
                    let info = try await runner.json(ArtifactInfo.self, ["gui-artifact-info", "--family", family, "--input", source])
                    var artifactSettings = settings
                    if let sectors = info.sectors { artifactSettings.geometry.sectors = sectors }
                    if let interleaved = info.interleaved { artifactSettings.outputs.interleave = interleaved }
                    let arguments = CommandBuilder.readback(artifactSettings, measured: measured, artifactPath: source, outputPath: output.path, size: size, samplesPerSector: samples)
                    _ = try await runner.capture(arguments) { [weak self] job in
                        Task { @MainActor in self?.runningJob = job }
                    }
                    if info.hasFileRegion, let start = info.drawingStart, let end = info.drawingEnd, end > start {
                        _ = try await runner.capture(CommandBuilder.overlay(artifactSettings, measured: measured, path: output.path, drawing: (start, end)))
                        fileRegion = true
                    }
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                if let previous = self.imagePath { try? FileManager.default.removeItem(atPath: previous) }
                self.image = NSImage(contentsOf: output)
                self.imagePath = output.path
                self.hasFileRegion = fileRegion
                self.isRendering = false
                self.status = "\(mode.rawValue) · \(size) px"
            } catch {
                guard !Task.isCancelled else { return }
                if let failure = error as? CLIFailure, failure.wasCancelled { return }
                self.isRendering = false
                self.status = app.text.translate(error.localizedDescription)
            }
        }
    }
}

struct PreviewView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: PreviewModel

    var body: some View {
        HSplitView {
            stage.frame(minWidth: 420)
            inspector.frame(minWidth: 280, idealWidth: 300, maxWidth: 360)
        }
        .onAppear {
            model.sync(with: app)
            model.refresh(app: app, debounce: false)
        }
        .onChange(of: app.compositePath) { _, _ in model.refresh(app: app) }
        .onChange(of: app.project?.tone) { _, _ in model.refresh(app: app) }
        .onChange(of: app.lastArtifactPath) { _, _ in
            model.sync(with: app)
            model.refresh(app: app)
        }
    }

    private var stage: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Mode", selection: $model.mode) {
                    ForEach(PreviewMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
                .onChange(of: model.mode) { _, _ in model.refresh(app: app, debounce: false) }
                Spacer()
                Button("Export PNG…") { exportPNG() }
                    .disabled(model.imagePath == nil)
            }
            .padding(10)
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = model.image {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                } else if !model.isRendering {
                    ContentUnavailableView("No preview yet", systemImage: "opticaldisc", description: Text(model.status))
                }
                if model.isRendering { ProgressView() }
            }
            Divider()
            HStack {
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.hasFileRegion {
                    Label("Files", systemImage: "square.fill")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.98, green: 0.8, blue: 0.08))
                }
            }
            .padding(8)
        }
    }

    private var inspector: some View {
        Form {
            if model.mode == .readback {
                Section("File to read back") {
                    PathRow(title: "File", path: model.artifactPath) {
                        if let url = FilePanels.open(types: [.iso, .wav, .raw]) {
                            Task { await model.useArtifact(url.path, app: app) }
                        }
                    }
                    if app.project?.discFamily == .cd, model.artifactPath.lowercased().hasSuffix(".raw") {
                        // A .raw track can come from elsewhere with no record of how it was made.
                        Toggle("Undo delay interleave", isOn: Binding(
                            get: { app.project?.outputs.interleave ?? true },
                            set: { value in
                                app.updateProject { $0.outputs.interleave = value }
                                model.refresh(app: app)
                            }
                        ))
                    }
                }
            }
            Section("Measured disc") {
                NumberField(title: "Inner radius", value: refreshing(\.innerRadiusMm), unit: "mm")
                NumberField(title: "Outer radius", value: refreshing(\.outerRadiusMm), unit: "mm")
                if app.project?.discFamily == .dvd {
                    NumberField(title: "Pitch, linear", value: refreshing(\.pitchLinear))
                    NumberField(title: "Pitch, quadratic", value: refreshing(\.pitchQuadratic))
                    NumberField(title: "Pitch, cubic", value: refreshing(\.pitchCubic))
                }
                Button("Use Project Geometry") {
                    if let project = app.project {
                        model.resetMeasured(project)
                        model.refresh(app: app)
                    }
                }
            }
            Section("Quality") {
                Stepper("Size: \(model.size) px", value: Binding(
                    get: { model.size },
                    set: { value in
                        model.size = value
                        model.refresh(app: app)
                    }
                ), in: 256...8192, step: 256)
                if app.project?.discFamily != .bd {
                    Stepper("Samples per sector: \(model.samplesPerSector)", value: Binding(
                        get: { model.samplesPerSector },
                        set: { value in
                            model.samplesPerSector = value
                            model.refresh(app: app)
                        }
                    ), in: 1...16)
                }
            }
            Section {
                Text(model.mode == .projection
                     ? "Shows where the picture lands if this design is burned to a disc with the measured geometry."
                     : "Reads a generated file back through the measured geometry. This maps bytes to positions; it doesn't simulate the optics, so only a real disc is proof.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func refreshing(_ key: WritableKeyPath<MeasuredGeometry, Double>) -> Binding<Double> {
        Binding(get: { model.measured[keyPath: key] }, set: { value in
            model.measured[keyPath: key] = value
            model.refresh(app: app)
        })
    }

    private func exportPNG() {
        guard let path = model.imagePath,
              let target = FilePanels.save(defaultName: "\(app.project?.name ?? "disc") preview.png", types: [.png])
        else { return }
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(atPath: path, toPath: target.path)
        } catch {
            app.report(error, title: "Couldn't export the preview")
        }
    }
}
