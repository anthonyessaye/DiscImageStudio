import DiscImageStudioKit
import SwiftUI
import UniformTypeIdentifiers

/// The calibration workflow: burn a known target, photograph the disc, correct the photo's
/// perspective, trace the curve that appears, and fit the disc's real geometry to the trace.
@MainActor
final class CalibrationModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case target, photo, trace
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .target: "1 Target"
            case .photo: "2 Photo"
            case .trace: "3 Trace"
            }
        }
    }

    static let photoMaxSize = 1600

    @Published var step: Step = .target
    @Published var info: CalibrationSessionInfo?
    @Published var targetImage: NSImage?
    @Published var outputPath = ""

    @Published var photo: NSImage?
    @Published var photoPixelSize = CGSize.zero
    @Published var photoBase64: String?
    @Published var outerPoints: [CalibrationPoint] = []
    @Published var holePoints: [CalibrationPoint] = []
    @Published var physicalOuterRadiusMm = 60.0
    @Published var rectificationSummary = ""

    @Published var rectified: NSImage?
    @Published var rectifiedRadiusMm = 63.0
    @Published var tracePoints: [CalibrationPoint] = []

    @Published var autoRange = true
    @Published var radiusRangeMm = 0.02
    @Published var fitDvdPitch = true
    @Published var outcome: CalibrationFitOutcome?
    @Published var selectedCandidateID: String?
    @Published var contourConfirmed = false
    @Published var isBusy = false
    @Published var statusMessage = "Create a target, or open a saved calibration record."

    private var photoFilePath: String?

    var selectedCandidate: CalibrationCandidate? {
        outcome?.candidates.first { $0.id == selectedCandidateID }
    }

    var canApply: Bool {
        guard let candidate = selectedCandidate else { return false }
        return contourConfirmed && candidate.accepted
    }

    private func invalidateFit() {
        outcome = nil
        selectedCandidateID = nil
        contourConfirmed = false
    }

    private func perform(_ message: String, app: AppModel, _ action: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        statusMessage = message
        Task {
            defer { isBusy = false }
            do {
                try await action()
            } catch {
                statusMessage = app.text.translate(error.localizedDescription)
                app.report(error, title: "Calibration step didn't finish")
            }
        }
    }

    // MARK: Target

    func createTarget(app: AppModel) {
        guard let project = app.project,
              let url = FilePanels.save(defaultName: "\(project.name).calibration.json",
                                        directory: app.projectURL?.deletingLastPathComponent(), types: [.json])
        else { return }
        perform("Creating the target…", app: app) { [self] in
            let runner = try app.requireRunner()
            var arguments = ["gui-calibration-create", "--session", url.path]
                + CommandBuilder.helperGeometry(project.discFamily, project.geometry)
            if project.discFamily == .cd { arguments += ["--cd-interleave", String(project.outputs.interleave)] }
            if project.discFamily == .bd { arguments += ["--invert", String(project.bluRay?.invertMapping ?? false)] }
            // Unlike the other helpers, this one reads a DVD's count from --sectors.
            if project.discFamily == .dvd {
                arguments += ["--sectors", String(project.geometry.sectors)]
            }
            let created = try await runner.json(CalibrationSessionInfo.self, arguments)
            try await install(created, app: app)
            statusMessage = "Target created. Generate it and burn it, then photograph the disc."
        }
    }

    func openSession(app: AppModel) {
        guard let url = FilePanels.open(types: [.json]) else { return }
        perform("Opening the calibration record…", app: app) { [self] in
            let runner = try app.requireRunner()
            let opened = try await runner.json(CalibrationSessionInfo.self, ["gui-calibration-info", "--session", url.path])
            try await install(opened, app: app)
            statusMessage = "Opened the calibration record."
        }
    }

    func install(_ session: CalibrationSessionInfo, app: AppModel) async throws {
        let runner = try app.requireRunner()
        info = session
        invalidateFit()
        fitDvdPitch = session.fitOptions?.fitDvdPitch ?? true
        autoRange = session.fitOptions?.autoRange ?? true
        radiusRangeMm = session.fitOptions?.radiusRangeMm ?? 0.02
        rectified = nil
        tracePoints = []
        rectificationSummary = ""
        step = .target

        let targetFile = try app.cacheFile("calibration-target-\(session.id.prefix(8)).png")
        _ = try await runner.capture(["gui-calibration-render", "--session", session.sessionPath, "--output", targetFile.path, "--size", "900"])
        targetImage = NSImage(contentsOf: targetFile)

        if let saved = session.photo, let data = Data(base64Encoded: saved.imagePngBase64) {
            let file = try app.cacheFile("calibration-photo-\(session.id.prefix(8)).png")
            try data.write(to: file)
            setPhoto(file: file, base64: saved.imagePngBase64)
            outerPoints = saved.outerBoundary
            holePoints = saved.holeBoundary
            physicalOuterRadiusMm = saved.physicalOuterRadiusMm
            tracePoints = saved.traces.flatMap(\.points).sorted { radius($0) < radius($1) }
            if saved.rectificationConfirmed {
                try await rectifyNow(app: app)
                step = .trace
            } else {
                step = .photo
            }
        } else {
            photo = nil
            photoBase64 = nil
            photoFilePath = nil
            outerPoints = []
            holePoints = []
        }
    }

    func exportPattern(app: AppModel) {
        guard let info, let url = FilePanels.save(defaultName: "calibration-\(info.id.prefix(8)).png", types: [.png]) else { return }
        perform("Exporting the pattern…", app: app) { [self] in
            _ = try await app.requireRunner().capture(["gui-calibration-render", "--session", info.sessionPath, "--output", url.path, "--encoding", "true"])
            statusMessage = "Pattern exported. To keep its scale correct, burn the generated file from this page."
        }
    }

    func chooseOutput() {
        guard let info else { return }
        let isDisc = info.parameters.family != .cd
        if let url = FilePanels.save(defaultName: "calibration-\(info.id.prefix(8)).\(isDisc ? "iso" : "wav")",
                                     types: isDisc ? [.iso] : [.wav, .raw]) {
            outputPath = url.path
        }
    }

    func generate(app: AppModel) {
        guard let info else { return }
        if outputPath.isEmpty { chooseOutput() }
        guard !outputPath.isEmpty else { return }
        let output = outputPath
        Task {
            do {
                let runner = try app.requireRunner()
                try await saveSession(app: app)
                try await app.runJob(title: "Generating the calibration file…") {
                    try runner.start(["gui-calibration-generate", "--session", info.sessionPath, "--output", output])
                }
                app.lastArtifactPath = output
                statusMessage = "Generated. Burn it, then import a photo of the disc."
            } catch {
                app.report(error, title: "Couldn't generate the calibration file")
            }
        }
    }

    // MARK: Photo

    func setPhoto(file: URL, base64: String) {
        photoFilePath = file.path
        photoBase64 = base64
        photo = NSImage(contentsOf: file)
        if let rep = photo?.representations.first {
            photoPixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
    }

    func importPhoto(app: AppModel) {
        guard let url = FilePanels.open(types: [.jpeg, .png, .heic, .tiff, .bmp]) else { return }
        perform("Loading the photo…", app: app) { [self] in
            // Reduced once, so outline points, the saved record and correction all share one
            // coordinate system. This also applies the photo's orientation tag.
            guard let image = DesignComposer.loadImage(path: url.path, maxSize: Self.photoMaxSize) else {
                throw ComposerError.unreadableImage(url.path)
            }
            let data = try DesignComposer.pngData(image)
            let file = try app.cacheFile("calibration-photo-\(UUID().uuidString.prefix(8)).png")
            try data.write(to: file)
            setPhoto(file: file, base64: data.base64EncodedString())
            suggestOutlines()
            rectified = nil
            tracePoints = []
            invalidateFit()
            step = .photo
            statusMessage = "Drag the cyan points onto the disc's outer edge, and the orange points onto the centre hole's edge."
        }
    }

    /// Starting outlines centred on the photo, which the user then drags into place.
    func suggestOutlines(count: Int = 8) {
        let width = photoPixelSize.width, height = photoPixelSize.height
        func ring(_ ratio: Double) -> [CalibrationPoint] {
            (0..<count).map { index in
                let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(count)
                return CalibrationPoint(x: (width - 1) / 2 + width * 0.43 * ratio * cos(angle),
                                        y: (height - 1) / 2 + height * 0.43 * ratio * sin(angle))
            }
        }
        outerPoints = ring(1)
        holePoints = ring(0.125)
    }

    private func rectifyNow(app: AppModel) async throws {
        guard let photoFilePath else { return }
        let runner = try app.requireRunner()
        let requestFile = try app.cacheFile("calibration-photo-request-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: requestFile) }
        let request = PhotoRectifyRequest(outer: outerPoints, hole: holePoints, physicalOuterRadiusMm: physicalOuterRadiusMm)
        try JSONEncoder().encode(request).write(to: requestFile)
        let output = try app.cacheFile("calibration-rectified-\(UUID().uuidString.prefix(8)).png")
        let result = try await runner.json(PhotoRectifyResult.self, [
            "gui-photo-rectify", "--request", requestFile.path, "--input", photoFilePath, "--output", output.path,
        ])
        guard result.succeeded else {
            throw CLIFailure(message: result.message, exitCode: 1, wasCancelled: false)
        }
        rectified = NSImage(contentsOf: output)
        rectifiedRadiusMm = result.canvasRadiusMm ?? physicalOuterRadiusMm + 3
        rectificationSummary = String(format: "Outer edge error %.1f px · hole error %.1f px", result.outerRmsPixels, result.holeRmsPixels)
    }

    func rectify(app: AppModel) {
        perform("Correcting the photo…", app: app) { [self] in
            try await rectifyNow(app: app)
            tracePoints = []
            invalidateFit()
            step = .trace
            try await saveSession(app: app)
            statusMessage = "Click along one curve from the inside out, at least 6 points."
        }
    }

    // MARK: Trace and fit

    private func radius(_ point: CalibrationPoint) -> Double { hypot(point.x, point.y) }

    /// Kept ordered by radius, which is the inside-out order the fitter requires.
    func addTracePoint(_ point: CalibrationPoint) {
        guard radius(point) <= physicalOuterRadiusMm else { return }
        let index = tracePoints.firstIndex { radius($0) > radius(point) } ?? tracePoints.count
        tracePoints.insert(point, at: index)
        invalidateFit()
    }

    func removeTracePoint(at index: Int) {
        guard tracePoints.indices.contains(index) else { return }
        tracePoints.remove(at: index)
        invalidateFit()
    }

    func clearTrace() {
        tracePoints = []
        invalidateFit()
    }

    private func saveSession(app: AppModel) async throws {
        guard let info else { return }
        let runner = try app.requireRunner()
        let requestFile = try app.cacheFile("calibration-save-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: requestFile) }
        let saved: CalibrationPhoto? = photoBase64.map { base64 in
            CalibrationPhoto(
                imagePngBase64: base64, outerBoundary: outerPoints, holeBoundary: holePoints,
                physicalOuterRadiusMm: physicalOuterRadiusMm,
                rectificationConfirmed: rectified != nil,
                traces: tracePoints.isEmpty ? [] : [CalibrationCrossTrace(points: tracePoints)]
            )
        }
        let request = CalibrationSaveRequest(photo: saved, radiusRangeMm: radiusRangeMm, autoRange: autoRange, fitDvdPitch: fitDvdPitch)
        try JSONEncoder().encode(request).write(to: requestFile)
        _ = try await runner.capture(["gui-calibration-save", "--session", info.sessionPath, "--request", requestFile.path])
    }

    func save(app: AppModel) {
        perform("Saving…", app: app) { [self] in
            try await saveSession(app: app)
            statusMessage = "Saved the target, photo, outlines and curve points."
        }
    }

    func solve(app: AppModel) {
        guard let info else { return }
        perform("Fitting all \(tracePoints.count) points…", app: app) { [self] in
            invalidateFit()
            try await saveSession(app: app)
            let result = try await app.requireRunner().json(CalibrationFitOutcome.self, [
                "gui-calibration-fit", "--session", info.sessionPath,
                "--auto", String(autoRange), "--range", CommandBuilder.number(radiusRangeMm), "--fit-dvd-pitch", String(fitDvdPitch),
            ])
            outcome = result
            selectedCandidateID = result.candidates.first?.id
            let warnings = result.warnings.map(app.text.translate).joined(separator: "\n")
            if !result.succeeded {
                statusMessage = warnings.isEmpty ? "The fit didn't succeed. All points were kept." : warnings
            } else if selectedCandidate?.accepted == false {
                statusMessage = "This candidate is too far from your points to apply. Fix the red points or add more."
            } else {
                var message = "Check that the orange prediction follows your curve before applying."
                if result.rangeExpanded { message += String(format: " The search widened to ±%.3g mm.", result.rangeMm) }
                if result.boundaryLimited { message += " The best fit is near the search limit, so add points or check their positions." }
                statusMessage = message
            }
        }
    }

    /// Writes the measured geometry into the project. The target record stays as it was.
    func apply(app: AppModel) {
        guard canApply, let p = selectedCandidate?.parameters else { return }
        app.updateProject(recompose: true) { document in
            document.geometry.innerRadiusMm = p.innerRadiusMm
            document.geometry.outerRadiusMm = p.outerRadiusMm
            document.geometry.sectors = p.sectors
            if p.family == .dvd {
                document.geometry.pitchLinear = p.pitchLinear
                document.geometry.pitchQuadratic = p.pitchQuadratic
                document.geometry.pitchCubic = p.pitchCubic
            }
            if p.family == .bd {
                document.bluRay = ProjectBluRaySettings(invertMapping: p.bluRayInvertMapping)
            }
        }
        statusMessage = "Applied to the project's \(p.family.label) geometry."
        app.appendLog("Calibration applied: inner \(p.innerRadiusMm), outer \(p.outerRadiusMm)")
    }
}

struct CalibrationView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: CalibrationModel

    var body: some View {
        HSplitView {
            stage.frame(minWidth: 460)
            inspector.frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
        }
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                switch model.step {
                case .target:
                    if let image = model.targetImage {
                        Image(nsImage: image).resizable().scaledToFit().padding(12)
                    } else {
                        ContentUnavailableView("No target yet", systemImage: "scope",
                                               description: Text("Create a target from this project's geometry."))
                    }
                case .photo:
                    if let photo = model.photo {
                        PhotoOutlineEditor(image: photo, pixelSize: model.photoPixelSize, outer: $model.outerPoints, hole: $model.holePoints)
                    } else {
                        ContentUnavailableView("No photo yet", systemImage: "camera",
                                               description: Text("Import a photo of the burned disc."))
                    }
                case .trace:
                    if let rectified = model.rectified {
                        TraceEditor(model: model, image: rectified)
                    } else {
                        ContentUnavailableView("Correct the photo first", systemImage: "perspective",
                                               description: Text("The trace uses the corrected photo."))
                    }
                }
                if model.isBusy { ProgressView() }
            }
            Divider()
            Text(model.statusMessage)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .textSelection(.enabled)
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        Form {
            Section {
                Picker("Step", selection: $model.step) {
                    ForEach(CalibrationModel.Step.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            switch model.step {
            case .target: targetSection
            case .photo: photoSection
            case .trace: traceSection
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var targetSection: some View {
        Section("Target") {
            Button("New Target from Project") { model.createTarget(app: app) }
            Button("Open Calibration Record…") { model.openSession(app: app) }
            if let info = model.info {
                LabeledContent("Disc", value: info.parameters.family.label)
                LabeledContent("Radii", value: "\(CommandBuilder.number(info.parameters.innerRadiusMm))–\(CommandBuilder.number(info.parameters.outerRadiusMm)) mm")
                LabeledContent("Sectors", value: info.parameters.sectors.formatted())
            }
        }
        if model.info != nil {
            Section("Generate") {
                PathRow(title: "Save to", path: model.outputPath) { model.chooseOutput() }
                Button("Generate Calibration File") { model.generate(app: app) }
                    .disabled(app.job != nil)
                Button("Export Pattern PNG…") { model.exportPattern(app: app) }
                Button("Go to Burn") { app.workspace = .burn }
                Button("Next: Photo") { model.step = .photo }
            }
        }
    }

    @ViewBuilder private var photoSection: some View {
        Section("Photo") {
            Button("Import Photo…") { model.importPhoto(app: app) }
                .disabled(model.info == nil)
            Picker("Disc size", selection: $model.physicalOuterRadiusMm) {
                Text("12 cm").tag(60.0)
                Text("8 cm").tag(40.0)
            }
            .pickerStyle(.segmented)
            Button("Reset Outlines") { model.suggestOutlines() }
                .disabled(model.photo == nil)
            Button("Correct Photo") { model.rectify(app: app) }
                .disabled(model.photo == nil || model.isBusy)
            if !model.rectificationSummary.isEmpty {
                Text(model.rectificationSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            Text("Place the points on the disc's physical edges, not the edge of the burned area or the clear plastic ring.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var traceSection: some View {
        Section("Curve") {
            LabeledContent("Points", value: String(model.tracePoints.count))
            Button("Clear Points") { model.clearTrace() }
                .disabled(model.tracePoints.isEmpty)
            Text("Click to add a point, and click a point to remove it. Follow one curve from the inside out.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let outcome = model.outcome, !outcome.candidates.isEmpty {
            Section("Result") {
                Picker("Candidate", selection: Binding(
                    get: { model.selectedCandidateID },
                    set: { id in
                        model.selectedCandidateID = id
                        model.contourConfirmed = false
                    }
                )) {
                    ForEach(Array(outcome.candidates.enumerated()), id: \.element.id) { index, candidate in
                        Text(String(format: "Candidate %d · %.3f mm", index + 1, candidate.rmsErrorMm)).tag(Optional(candidate.id))
                    }
                }
                if let candidate = model.selectedCandidate {
                    LabeledContent("Inner radius", value: String(format: "%.6f mm", candidate.parameters.innerRadiusMm))
                    LabeledContent("Outer radius", value: String(format: "%.6f mm", candidate.parameters.outerRadiusMm))
                    LabeledContent("Mean error", value: String(format: "%.3f mm", candidate.rmsErrorMm))
                    LabeledContent("Largest error", value: String(format: "%.3f mm", candidate.maxErrorMm))
                    if !candidate.accepted {
                        Text("Not accepted: too far from the points to apply.")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Toggle("The orange prediction follows my curve", isOn: $model.contourConfirmed)
                        .disabled(!candidate.accepted)
                    Button("Apply to Project") { model.apply(app: app) }
                        .disabled(!model.canApply)
                }
                ForEach(outcome.warnings, id: \.self) { warning in
                    Text(app.text.translate(warning)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section("Search") {
            Toggle("Automatic range", isOn: $model.autoRange)
            if !model.autoRange {
                NumberField(title: "Radius range", value: $model.radiusRangeMm, unit: "mm")
            }
            if model.info?.parameters.family == .dvd {
                Toggle("Fit DVD pitch", isOn: $model.fitDvdPitch)
            }
            Button("Fit Geometry") { model.solve(app: app) }
                .disabled(model.tracePoints.count < 6 || model.isBusy)
            Button("Save Record") { model.save(app: app) }
                .disabled(model.info == nil || model.isBusy)
        }
    }
}

/// Fits an image of a given size into the view and converts between the two spaces.
private struct FitMapping {
    var viewSize: CGSize
    var imageSize: CGSize

    var scale: CGFloat { min(viewSize.width / max(imageSize.width, 1), viewSize.height / max(imageSize.height, 1)) }
    var origin: CGPoint {
        CGPoint(x: (viewSize.width - imageSize.width * scale) / 2, y: (viewSize.height - imageSize.height * scale) / 2)
    }
    var imageRect: CGRect {
        CGRect(origin: origin, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
    }
    func toView(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
    func toImage(_ point: CGPoint) -> (x: Double, y: Double) { ((point.x - origin.x) / scale, (point.y - origin.y) / scale) }
}

/// Drag the outer-edge and hole-edge control points into place on the photo.
struct PhotoOutlineEditor: View {
    let image: NSImage
    let pixelSize: CGSize
    @Binding var outer: [CalibrationPoint]
    @Binding var hole: [CalibrationPoint]
    @State private var dragging: (isOuter: Bool, index: Int)?

    var body: some View {
        GeometryReader { proxy in
            let map = FitMapping(viewSize: proxy.size, imageSize: pixelSize)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: map.imageRect.width, height: map.imageRect.height)
                    .offset(x: map.imageRect.minX, y: map.imageRect.minY)
                Canvas { context, _ in
                    drawRing(&context, outer, color: .cyan, map)
                    drawRing(&context, hole, color: .orange, map)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragging == nil { dragging = nearest(to: value.startLocation, map) }
                        guard let dragging else { return }
                        let position = map.toImage(value.location)
                        let point = CalibrationPoint(x: min(max(position.x, 0), pixelSize.width - 1),
                                                     y: min(max(position.y, 0), pixelSize.height - 1))
                        if dragging.isOuter { outer[dragging.index] = point } else { hole[dragging.index] = point }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .padding(12)
    }

    private func drawRing(_ context: inout GraphicsContext, _ points: [CalibrationPoint], color: Color, _ map: FitMapping) {
        guard points.count > 1 else { return }
        var path = Path()
        path.addLines(points.map { map.toView($0.x, $0.y) })
        path.closeSubpath()
        context.stroke(path, with: .color(color), lineWidth: 1.5)
        for point in points {
            let p = map.toView(point.x, point.y)
            let box = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: box), with: .color(color))
            context.stroke(Path(ellipseIn: box), with: .color(.white), lineWidth: 1)
        }
    }

    private func nearest(to location: CGPoint, _ map: FitMapping) -> (isOuter: Bool, index: Int)? {
        var best: (isOuter: Bool, index: Int)?
        var bestDistance: CGFloat = 24
        for (isOuter, points) in [(true, outer), (false, hole)] {
            for (index, point) in points.enumerated() {
                let p = map.toView(point.x, point.y)
                let d = hypot(p.x - location.x, p.y - location.y)
                if d < bestDistance {
                    bestDistance = d
                    best = (isOuter, index)
                }
            }
        }
        return best
    }
}

/// Click to mark the curve on the corrected photo. Trace points are in disc millimetres,
/// centred on the disc, with y down.
struct TraceEditor: View {
    @ObservedObject var model: CalibrationModel
    let image: NSImage

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let mmPerPoint = 2 * model.rectifiedRadiusMm / max(side, 1)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let toView = { (p: CalibrationPoint) in
                CGPoint(x: center.x + p.x / mmPerPoint, y: center.y + p.y / mmPerPoint)
            }
            ZStack {
                Image(nsImage: image).resizable().scaledToFit()
                Canvas { context, _ in
                    if let candidate = model.selectedCandidate, candidate.outline.count > 1 {
                        var path = Path()
                        path.addLines(candidate.outline.map(toView))
                        context.stroke(path, with: .color(.orange), lineWidth: 2)
                    }
                    let outliers = Set(model.selectedCandidate?.outlierPointIndices ?? [])
                    for (index, point) in model.tracePoints.enumerated() {
                        let p = toView(point)
                        let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: box), with: .color(outliers.contains(index) ? .red : .cyan))
                        context.stroke(Path(ellipseIn: box), with: .color(.white), lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                if let index = model.tracePoints.firstIndex(where: {
                    let p = toView($0)
                    return hypot(p.x - location.x, p.y - location.y) < 8
                }) {
                    model.removeTracePoint(at: index)
                } else {
                    model.addTracePoint(CalibrationPoint(x: (location.x - center.x) * mmPerPoint, y: (location.y - center.y) * mmPerPoint))
                }
            }
        }
        .padding(12)
    }
}
