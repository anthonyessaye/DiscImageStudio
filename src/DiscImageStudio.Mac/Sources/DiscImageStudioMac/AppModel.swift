import AppKit
import DiscImageStudioKit
import SwiftUI
import UniformTypeIdentifiers

/// A design layer in memory. Panel order is topmost-first; project files store bottom-first.
struct DesignLayer: Identifiable, Equatable {
    var id: String
    var name: String
    var imagePath: String
    var visible: Bool
    var translateXMm: Double
    var translateYMm: Double
    var rotationDeg: Double
    var scale: Double
    var image: CGImage?
    var baseWidthMm: Double = 0
    var baseHeightMm: Double = 0

    init(_ layer: ProjectLayer) {
        id = layer.id
        name = layer.name
        imagePath = layer.imagePath
        visible = layer.visible
        translateXMm = layer.translateXMm
        translateYMm = layer.translateYMm
        rotationDeg = layer.rotationDeg
        scale = layer.scale
    }

    var projectLayer: ProjectLayer {
        ProjectLayer(id: id, name: name, imagePath: imagePath, visible: visible,
                     translateXMm: translateXMm, translateYMm: translateYMm,
                     rotationDeg: rotationDeg, scale: scale)
    }

    /// False when the image file couldn't be read, which leaves a layer nothing can draw.
    mutating func loadImage(contentOuterRadiusMm: Double) -> Bool {
        guard let decoded = DesignComposer.loadImage(path: imagePath) else {
            image = nil
            return false
        }
        image = decoded
        let size = DesignComposer.baseSize(imageWidth: decoded.width, imageHeight: decoded.height, contentOuterRadiusMm: contentOuterRadiusMm)
        baseWidthMm = size.width
        baseHeightMm = size.height
        return true
    }

    static func == (a: DesignLayer, b: DesignLayer) -> Bool {
        a.projectLayer == b.projectLayer && a.image === b.image
    }
}

struct ActiveJob {
    var title: String
    var fraction: Double?
    var detail: String
    var cancel: () -> Void
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct RecentProject: Codable, Identifiable, Equatable {
    var path: String
    var name: String
    var family: DiscFamily
    var id: String { path }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let runner: CLIRunner?
    let text = EngineText.locate()

    @Published var workspace: Workspace = .home
    @Published var project: ProjectDocument?
    @Published var projectURL: URL?
    @Published var isDirty = false
    @Published var layers: [DesignLayer] = []
    @Published var selectedLayerID: String?
    @Published var compositePath: String?
    @Published var catalog: DiscPresetCatalog?
    @Published var recents: [RecentProject] = []
    @Published var log: [String] = []
    @Published var job: ActiveJob?
    @Published var alert: AppAlert?
    @Published var showingNewProject = false
    @Published var showingProjectSettings = false
    @Published var tonePreview: NSImage?
    @Published var tonePreviewStatus = "Import an image to see the preview."
    /// The most recent generated file, used as the default read-back and burn source.
    @Published var lastArtifactPath: String?

    // @AppStorage doesn't publish changes from inside an ObservableObject, so a new theme
    // wouldn't apply until something else redrew the window.
    @Published var themeRaw = UserDefaults.standard.string(forKey: "theme") ?? AppTheme.system.rawValue {
        didSet { UserDefaults.standard.set(themeRaw, forKey: "theme") }
    }
    @Published var projectsDirectory = UserDefaults.standard.string(forKey: "projectsDirectory") ?? "" {
        didSet { UserDefaults.standard.set(projectsDirectory, forKey: "projectsDirectory") }
    }
    @Published var cacheDirectoryOverride = UserDefaults.standard.string(forKey: "cacheDirectory") ?? "" {
        didSet { UserDefaults.standard.set(cacheDirectoryOverride, forKey: "cacheDirectory") }
    }

    private var compositeTask: Task<Void, Never>?
    private var toneTask: Task<Void, Never>?
    private var toneJob: CLIJob?
    private var compositeRevision = 0
    private var exportedRevision = -1
    private var exportedPath: String?
    private var isLoading = false

    private static let recentsKey = "recentProjects"
    private static let maxRecents = 12

    var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .system }

    init() {
        runner = CLIRunner.locate()
        if let data = UserDefaults.standard.data(forKey: Self.recentsKey),
           let saved = try? JSONDecoder().decode([RecentProject].self, from: data) {
            recents = saved
        }
        Task { await reloadPresets() }
    }

    // MARK: Paths

    var cacheDirectory: URL {
        if !cacheDirectoryOverride.isEmpty { return URL(fileURLWithPath: cacheDirectoryOverride, isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiscImageStudio", isDirectory: true)
    }

    var defaultProjectsDirectory: URL {
        if !projectsDirectory.isEmpty, FileManager.default.fileExists(atPath: projectsDirectory) {
            return URL(fileURLWithPath: projectsDirectory, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiscImageStudio Projects", isDirectory: true)
    }

    var userPresetsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiscImageStudio/disc-presets.json")
    }

    func cacheFile(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        return cacheDirectory.appendingPathComponent(name)
    }

    /// Deletes only files the app itself names, never the folder or anything else in it,
    /// since the cache location can be pointed at any folder.
    func clearCache() {
        let prefixes = ["design-composite-", "design-tone-", "design-thumbnail", "cd-live-", "dvd-live-", "bd-live-",
                        "calibration-photo-", "calibration-rectified-", "calibration-target-", "project-check-"]
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where prefixes.contains(where: file.lastPathComponent.hasPrefix) {
            try? FileManager.default.removeItem(at: file)
        }
        exportedRevision = -1
        exportedPath = nil
    }

    // MARK: Errors and logging

    func report(_ error: Error, title: String = "That didn't work") {
        if let failure = error as? CLIFailure, failure.wasCancelled { return }
        let message = text.translate(error.localizedDescription)
        appendLog("\(title): \(message)")
        alert = AppAlert(title: title, message: message)
    }

    func appendLog(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.append("[\(time)] \(text.translate(line))")
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    func requireRunner() throws -> CLIRunner {
        guard let runner else {
            throw CLIFailure(
                message: "The disc engine wasn't found in this app. Run scripts/build-app.sh, or set DISC_IMAGE_STUDIO_CLI during development.",
                exitCode: -1, wasCancelled: false
            )
        }
        return runner
    }

    // MARK: Presets

    func reloadPresets() async {
        guard let runner else { return }
        do {
            catalog = try await runner.json(DiscPresetCatalog.self, ["gui-presets", "--user-file", userPresetsFile.path])
        } catch {
            report(error, title: "Couldn't load disc presets")
        }
    }

    func saveCurrentGeometryAsPreset(name: String) async {
        guard let project else { return }
        do {
            let runner = try requireRunner()
            try FileManager.default.createDirectory(at: userPresetsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            var arguments = ["gui-preset-save", "--user-file", userPresetsFile.path,
                             "--id", "user-\(UUID().uuidString.prefix(8).lowercased())", "--name", name,
                             "--family", project.discFamily.rawValue,
                             "--sectors", String(project.geometry.sectors),
                             "--r0", CommandBuilder.number(project.geometry.innerRadiusMm),
                             "--r1", CommandBuilder.number(project.geometry.outerRadiusMm)]
            switch project.discFamily {
            case .dvd:
                arguments += ["--pitch-linear", CommandBuilder.number(project.geometry.pitchLinear),
                              "--pitch-quadratic", CommandBuilder.number(project.geometry.pitchQuadratic),
                              "--pitch-cubic", CommandBuilder.number(project.geometry.pitchCubic)]
            case .bd:
                arguments += ["--invert", String(project.bluRay?.invertMapping ?? false)]
            case .cd:
                break
            }
            _ = try await runner.capture(arguments)
            await reloadPresets()
        } catch {
            report(error, title: "Couldn't save the preset")
        }
    }

    // MARK: Project lifecycle

    /// True when it's safe to replace the open project, asking first if there's unsaved work.
    func confirmDiscardChanges() -> Bool {
        guard project != nil, isDirty else { return true }
        let panel = NSAlert()
        panel.messageText = "Save changes to “\(project?.name ?? "this project")”?"
        panel.informativeText = "Your changes will be lost if you don't save them."
        panel.addButton(withTitle: "Save")
        panel.addButton(withTitle: "Don't Save")
        panel.addButton(withTitle: "Cancel")
        switch panel.runModal() {
        case .alertFirstButtonReturn:
            // Saving is async because it validates through the engine. Keeping the window
            // open until it succeeds means a failed save can't lose the work.
            Task { await save() }
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func createProject(name: String, preset: DiscPreset, directory: URL) async {
        let family = preset.family
        let fileBase = directory.appendingPathComponent(name)
        let url = fileBase.appendingPathExtension(ProjectDocument.fileExtension)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            alert = AppAlert(title: "That project already exists", message: "\(url.path) is already there. Choose another name or open it instead.")
            return
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let label = family == .cd ? "CD_IMAGE" : family == .dvd ? "DISC_IMAGE" : "BD_IMAGE"
        let document = ProjectDocument(
            name: name, discFamily: family, geometry: preset.geometry,
            outputs: ProjectOutputs(outputPath: fileBase.appendingPathExtension(family == .cd ? "wav" : "iso").path, volumeLabel: label),
            createdUtc: now, modifiedUtc: now, tone: .photo,
            bluRay: family == .bd ? ProjectBluRaySettings(invertMapping: preset.invertMapping) : nil
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await check(document)
            try document.save(to: url)
            install(document, url: url)
            workspace = .design
        } catch {
            report(error, title: "Couldn't create the project")
        }
    }

    /// Runs a document through the engine's own project validator.
    func check(_ document: ProjectDocument) async throws {
        let runner = try requireRunner()
        let file = try cacheFile("project-check-\(UUID().uuidString).discproj")
        defer { try? FileManager.default.removeItem(at: file) }
        try document.save(to: file)
        _ = try await runner.capture(["gui-project-validate", "--input", file.path])
    }

    func open(_ url: URL) async {
        do {
            let runner = try requireRunner()
            _ = try await runner.capture(["gui-project-validate", "--input", url.path])
            let document = try ProjectDocument.load(from: url)
            install(document, url: url)
            workspace = .design
        } catch {
            recents.removeAll { $0.path == url.path }
            persistRecents()
            report(error, title: "Couldn't open the project")
        }
    }

    func openWithPanel() {
        guard confirmDiscardChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .json]
        if panel.runModal() == .OK, let url = panel.url {
            Task { await open(url) }
        }
    }

    private func install(_ document: ProjectDocument, url: URL) {
        isLoading = true
        defer { isLoading = false }
        project = document
        projectURL = url
        isDirty = false
        compositePath = nil
        tonePreview = nil
        lastArtifactPath = FileManager.default.fileExists(atPath: document.outputs.outputPath) ? document.outputs.outputPath : nil
        exportedRevision = -1

        var unreadable: [String] = []
        // Stored bottom-first, shown topmost-first.
        layers = document.layers.reversed().compactMap { stored in
            var layer = DesignLayer(stored)
            if layer.loadImage(contentOuterRadiusMm: document.geometry.outerRadiusMm) { return layer }
            unreadable.append(stored.imagePath)
            return nil
        }
        selectedLayerID = layers.first?.id
        if !unreadable.isEmpty {
            alert = AppAlert(title: "Some layer images couldn't be read", message: unreadable.joined(separator: "\n"))
        }
        addRecent(url: url, document: document)
        scheduleComposite()
    }

    func closeProject() {
        guard confirmDiscardChanges() else { return }
        project = nil
        projectURL = nil
        isDirty = false
        layers = []
        selectedLayerID = nil
        compositePath = nil
        tonePreview = nil
        workspace = .home
    }

    func save() async {
        guard let url = projectURL else { return saveAs() }
        await write(to: url)
    }

    func saveAs() {
        guard let project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProjectDocument.fileExtension) ?? .json]
        panel.nameFieldStringValue = project.name
        panel.directoryURL = projectURL?.deletingLastPathComponent() ?? defaultProjectsDirectory
        if panel.runModal() == .OK, let url = panel.url {
            Task { await write(to: url) }
        }
    }

    private func write(to url: URL) async {
        guard var document = project else { return }
        document.layers = layers.reversed().map(\.projectLayer)
        document.modifiedUtc = ISO8601DateFormatter().string(from: Date())
        document.thumbnailPngBase64 = await renderThumbnail()
        do {
            try await check(document)
            try document.save(to: url)
            project = document
            projectURL = url
            isDirty = false
            addRecent(url: url, document: document)
            appendLog("Saved \(url.path)")
        } catch {
            report(error, title: "Couldn't save the project")
        }
    }

    private func addRecent(url: URL, document: ProjectDocument) {
        recents.removeAll { $0.path == url.path }
        recents.insert(RecentProject(path: url.path, name: document.name, family: document.discFamily), at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
        persistRecents()
    }

    func removeRecent(_ recent: RecentProject) {
        recents.removeAll { $0 == recent }
        persistRecents()
    }

    private func persistRecents() {
        UserDefaults.standard.set(try? JSONEncoder().encode(recents), forKey: Self.recentsKey)
    }

    /// Every edit to the project goes through here so the dirty flag and previews stay right.
    func updateProject(recompose: Bool = false, _ change: (inout ProjectDocument) -> Void) {
        guard var document = project else { return }
        change(&document)
        guard document != project else { return }
        project = document
        if !isLoading { isDirty = true }
        if recompose { scheduleComposite() } else { scheduleTonePreview() }
    }

    var jobSettings: DiscJobSettings? {
        project.map(DiscJobSettings.init(project:))
    }

    var canvasOuterRadiusMm: Double {
        guard let project else { return 60 }
        return DesignComposer.canvasOuterRadius(family: project.discFamily, geometry: project.geometry)
    }

    // MARK: Layers

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .gif, .tiff, .heic, .webP]
        guard panel.runModal() == .OK, let geometry = project?.geometry else { return }
        var failed: [String] = []
        var firstAdded: String?
        for url in panel.urls {
            var layer = DesignLayer(ProjectLayer(name: url.lastPathComponent, imagePath: url.path))
            guard layer.loadImage(contentOuterRadiusMm: geometry.outerRadiusMm) else {
                failed.append(url.path)
                continue
            }
            layers.insert(layer, at: 0)
            if firstAdded == nil { firstAdded = layer.id }
        }
        if let firstAdded {
            selectedLayerID = firstAdded
            layersEdited()
        }
        if !failed.isEmpty {
            alert = AppAlert(title: "Some images couldn't be imported", message: failed.joined(separator: "\n"))
        }
    }

    func removeSelectedLayer() {
        guard let index = layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        layers.remove(at: index)
        selectedLayerID = layers.isEmpty ? nil : layers[min(index, layers.count - 1)].id
        layersEdited()
    }

    func moveSelectedLayer(by offset: Int) {
        guard let index = layers.firstIndex(where: { $0.id == selectedLayerID }) else { return }
        let target = index + offset
        guard layers.indices.contains(target) else { return }
        layers.swapAt(index, target)
        layersEdited()
    }

    func updateLayer(_ id: String, _ change: (inout DesignLayer) -> Void) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        change(&layers[index])
        layersEdited()
    }

    private func layersEdited() {
        isDirty = true
        scheduleComposite()
    }

    // MARK: Composite

    private func renderItems() -> [ComposerLayer] {
        layers.compactMap { layer in
            guard layer.visible, let image = layer.image else { return nil }
            return ComposerLayer(image: image, baseWidthMm: layer.baseWidthMm, baseHeightMm: layer.baseHeightMm,
                                 translateXMm: layer.translateXMm, translateYMm: layer.translateYMm,
                                 rotationDeg: layer.rotationDeg, scale: layer.scale)
        }
    }

    /// Debounced so that dragging a layer only renders once the drag pauses.
    func scheduleComposite() {
        compositeRevision += 1
        let revision = compositeRevision
        compositeTask?.cancel()
        compositeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.renderPreviewComposite(revision: revision)
        }
    }

    private func renderPreviewComposite(revision: Int) async {
        guard let project else { return }
        let items = renderItems()
        guard !items.isEmpty else {
            compositePath = nil
            tonePreview = nil
            tonePreviewStatus = "Import an image to see the preview."
            return
        }
        let radius = canvasOuterRadiusMm
        do {
            let url = try cacheFile("design-composite-\(project.discFamily.rawValue).png")
            try await Task.detached(priority: .userInitiated) {
                let image = try DesignComposer.render(layers: items, canvasOuterRadiusMm: radius, outputSize: DesignComposer.previewSize)
                try DesignComposer.writePNG(image, to: url)
            }.value
            guard revision == compositeRevision else { return }
            compositePath = url.path
            scheduleTonePreview()
        } catch {
            report(error, title: "Couldn't compose the design")
        }
    }

    /// The full-quality composite a generation job needs. Reused until the layers change.
    func ensureExportComposite() async throws -> String {
        guard let project else { throw ComposerError.renderFailed }
        let items = renderItems()
        guard !items.isEmpty else {
            throw CLIFailure(message: "Import an image on the Design page first.", exitCode: -1, wasCancelled: false)
        }
        if exportedRevision == compositeRevision, let exportedPath, FileManager.default.fileExists(atPath: exportedPath) {
            return exportedPath
        }
        let revision = compositeRevision
        let radius = canvasOuterRadiusMm
        let url = try cacheFile("design-composite-\(project.discFamily.rawValue)-export.png")
        try await Task.detached(priority: .userInitiated) {
            let image = try DesignComposer.render(layers: items, canvasOuterRadiusMm: radius, outputSize: DesignComposer.exportSize)
            try DesignComposer.writePNG(image, to: url)
        }.value
        exportedRevision = revision
        exportedPath = url.path
        return url.path
    }

    private func renderThumbnail() async -> String? {
        let items = renderItems()
        guard !items.isEmpty else { return nil }
        let radius = canvasOuterRadiusMm
        return await Task.detached(priority: .utility) { () -> String? in
            guard let image = try? DesignComposer.render(layers: items, canvasOuterRadiusMm: radius, outputSize: DesignComposer.thumbnailSize),
                  let data = try? DesignComposer.pngData(image) else { return nil }
            return data.base64EncodedString()
        }.value
    }

    // MARK: Tone preview

    func scheduleTonePreview() {
        toneTask?.cancel()
        toneJob?.cancel()
        guard let compositePath, let settings = jobSettings, let runner else { return }
        tonePreviewStatus = "Rendering…"
        toneTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            do {
                let output = try self.cacheFile("design-tone-\(UUID().uuidString).png")
                defer { try? FileManager.default.removeItem(at: output) }
                let arguments = CommandBuilder.tonePreview(settings, sourcePath: compositePath, outputPath: output.path)
                _ = try await runner.capture(arguments) { [weak self] job in
                    Task { @MainActor in self?.toneJob = job }
                }
                guard !Task.isCancelled else { return }
                if settings.hasFiles {
                    try await self.applyFileRegion(to: output.path, settings: settings, measured: MeasuredGeometry(geometry: settings.geometry))
                }
                guard !Task.isCancelled else { return }
                self.tonePreview = NSImage(contentsOf: output)
                self.tonePreviewStatus = "Live preview"
            } catch {
                if let failure = error as? CLIFailure, failure.wasCancelled { return }
                guard !Task.isCancelled else { return }
                self.tonePreviewStatus = self.text.translate(error.localizedDescription)
            }
        }
    }

    /// Marks where files will sit on a preview. Presentation only: it never touches output.
    func applyFileRegion(to path: String, settings: DiscJobSettings, measured: MeasuredGeometry) async throws {
        let runner = try requireRunner()
        let plan = try await runner.json(DrawingPlan.self, CommandBuilder.drawingPlan(settings))
        _ = try await runner.capture(CommandBuilder.overlay(settings, measured: measured, path: path, drawing: (plan.start, plan.end)))
    }

    // MARK: Long-running jobs

    /// Runs one job with progress in the dock. Only one runs at a time, as on Windows.
    func runJob(title: String, start: () throws -> CLIJob) async throws {
        guard job == nil else {
            throw CLIFailure(message: "Another job is still running.", exitCode: -1, wasCancelled: false)
        }
        let running = try start()
        job = ActiveJob(title: title, fraction: nil, detail: "", cancel: { running.cancel() })
        appendLog(title)
        defer { job = nil }
        var lastError: String?
        for await event in running.events {
            switch event {
            case .progress(let progress):
                job?.fraction = progress.fraction ?? job?.fraction
                job?.detail = text.translate(progress.message)
            case .stdout(let line):
                if !line.isEmpty {
                    appendLog(line)
                    job?.detail = text.translate(line)
                }
            case .stderr(let line):
                if !line.isEmpty {
                    appendLog(line)
                    lastError = line
                }
            }
        }
        let result = await running.wait()
        if result.wasCancelled {
            appendLog("Cancelled.")
            throw CLIFailure(message: "Cancelled.", exitCode: result.exitCode, wasCancelled: true)
        }
        guard result.succeeded else {
            var message = lastError ?? "The job failed with exit code \(result.exitCode)."
            if message.hasPrefix("error: ") { message.removeFirst(7) }
            throw CLIFailure(message: message, exitCode: result.exitCode, wasCancelled: false)
        }
    }

    func generate() async {
        guard let settings = jobSettings else { return }
        do {
            guard !settings.outputs.outputPath.isEmpty else {
                throw CLIFailure(message: "Choose where to save the output first.", exitCode: -1, wasCancelled: false)
            }
            let runner = try requireRunner()
            let composite = try await ensureExportComposite()
            let arguments = CommandBuilder.generate(settings, compositePath: composite)
            try await runJob(title: "Generating \(settings.family.label) output…") { try runner.start(arguments) }
            lastArtifactPath = settings.outputs.outputPath
            appendLog("Finished: \(settings.outputs.outputPath)")
        } catch {
            report(error, title: "Generation didn't finish")
        }
    }
}

// MARK: Shared panels

@MainActor
enum FilePanels {
    static func save(defaultName: String, directory: URL? = nil, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = directory
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func open(types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func folder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension UTType {
    static var wav: UTType { UTType(filenameExtension: "wav") ?? .audio }
    static var raw: UTType { UTType(filenameExtension: "raw") ?? .data }
    static var iso: UTType { UTType(filenameExtension: "iso") ?? .data }
}
