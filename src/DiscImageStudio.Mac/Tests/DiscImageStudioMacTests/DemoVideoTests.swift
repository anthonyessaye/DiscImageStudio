import AppKit
import DiscImageStudioKit
import SwiftUI
import XCTest
@testable import DiscImageStudioMac

/// What the demo draws over the app: a caption, an opening or closing card, or the New
/// Project sheet (real sheets are separate windows, which an off-screen capture can't see).
@MainActor
final class DemoState: ObservableObject {
    @Published var caption: String?
    @Published var card: (title: String, detail: String)?
    @Published var showNewProject = false
    @Published var hideCaptionBar = false
}

/// The real pages inside a redrawn frame. macOS's title bar and sidebar materials need the
/// window server, so they don't draw in an off-screen window: the selected sidebar row comes
/// out black. The README says that this frame is redrawn; everything inside it is the app.
struct DemoRoot: View {
    @ObservedObject var demo: DemoState
    @ObservedObject var app: AppModel
    let preview: PreviewModel
    let burn: BurnModel
    let calibration: CalibrationModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 0) {
                    titleBar
                    Divider()
                    HStack(spacing: 0) {
                        sidebar
                        Divider()
                        VStack(spacing: 0) {
                            page.frame(maxWidth: .infinity, maxHeight: .infinity)
                            JobDock()
                        }
                    }
                }
                if demo.showNewProject {
                    Color.black.opacity(0.45)
                    NewProjectSheet()
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if !demo.hideCaptionBar {
                Text(demo.caption ?? " ")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(Color(red: 0.08, green: 0.09, blue: 0.13))
            }
        }
        .overlay {
            if let card = demo.card {
                ZStack {
                    Color(red: 0.08, green: 0.09, blue: 0.13)
                    VStack(spacing: 16) {
                        Text(card.title).font(.system(size: 46, weight: .semibold))
                        Text(card.detail)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 820)
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .environmentObject(app)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var page: some View {
        switch app.workspace {
        case .home: HomeView()
        case .design: DesignView()
        case .preview: PreviewView(model: preview)
        case .export: ExportView()
        case .burn: BurnView(model: burn)
        case .calibration: CalibrationView(model: calibration)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.22)).frame(width: 12, height: 12) }
            }
            Text(app.project.map { $0.name + (app.isDirty ? " — Edited" : "") } ?? "Disc Image Studio")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if app.project != nil {
                Image(systemName: "slider.horizontal.3")
                Image(systemName: "square.and.arrow.down")
                if let next = app.workspace.next {
                    Label("Next: \(next.rawValue)", systemImage: "arrow.right").font(.system(size: 13))
                }
            }
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(.home)
            if let project = app.project {
                Text(project.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                ForEach([Workspace.design, .preview, .export, .burn, .calibration]) { row($0) }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 190)
    }

    private func row(_ workspace: Workspace) -> some View {
        Label(workspace.rawValue, systemImage: workspace.systemImage)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(app.workspace == workspace ? 1 : 0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(app.workspace == workspace ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Stands in as the active window, so selection and controls draw as they do in use.
final class DemoWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// Renders the demo video's frames. The steps are scripted, while the pages, engine output,
/// progress and calibration result are all real. Run through scripts/render-demo.sh.
@MainActor
final class DemoVideoTests: XCTestCase {
    private var frames: URL!
    private var work: URL!
    private var window: DemoWindow!
    private var frameIndex = 0
    private var frameList: [(name: String, hold: Double)] = []
    private var gifRange: Range<Int>?
    private let demo = DemoState()

    private static let framePeriod = 1.0 / 24

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["DISC_IMAGE_STUDIO_DEMO_FRAMES"] ?? ""
        try XCTSkipIf(path.isEmpty, "Set DISC_IMAGE_STUDIO_DEMO_FRAMES, or use scripts/render-demo.sh.")
        try XCTSkipIf((ProcessInfo.processInfo.environment["DISC_IMAGE_STUDIO_CLI"] ?? "").isEmpty, "Set DISC_IMAGE_STUDIO_CLI.")
        frames = URL(fileURLWithPath: path, isDirectory: true)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("DiscImageStudio Demo", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
        window?.close()
    }

    // MARK: Recording

    private func pump(_ seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            await Task.yield()
        } while Date() < deadline
    }

    /// Waits off-camera, so a slow render doesn't become dead time in the video.
    private func wait(_ what: String, timeout: Double = 600, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(what)")
                throw CLIFailure(message: "Timed out waiting for \(what)", exitCode: -1, wasCancelled: false)
            }
            await pump(0.05)
        }
        await pump(0.25)
    }

    /// Adds the window's current look to the video, showing for `hold` seconds.
    private func capture(hold: Double = DemoVideoTests.framePeriod) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        frameIndex += 1
        let name = String(format: "f%05d.png", frameIndex)
        try data.write(to: frames.appendingPathComponent(name))
        frameList.append((name, hold))
    }

    /// A clean image for the README, without the caption bar.
    private func captureStill(_ name: String) async throws {
        demo.hideCaptionBar = true
        await pump(0.2)
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try DesignComposer.writePNG(try XCTUnwrap(rep.cgImage), to: frames.appendingPathComponent("still-\(name).png"))
        demo.hideCaptionBar = false
        await pump(0.2)
    }

    private func show(_ caption: String?, hold: Double, still: String? = nil) async throws {
        if let still { try await captureStill(still) }
        demo.caption = caption
        await pump(0.15)
        try capture(hold: hold)
    }

    private func concatFile(_ entries: ArraySlice<(name: String, hold: Double)>) -> String {
        var text = ""
        for entry in entries {
            text += "file '\(entry.name)'\nduration \(entry.hold)\n"
        }
        // The concat format ignores the last duration unless the last file is repeated.
        if let last = entries.last { text += "file '\(last.name)'\n" }
        return text
    }

    // MARK: Demo content

    /// A sunset, drawn here so the demo needs no third-party picture. Its soft gradients show
    /// off dithering, and its hard skyline shows how sharp a disc's picture can get.
    private func makeArtwork() throws -> String {
        let size = 1600
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(size)
        let color = { (r: CGFloat, g: CGFloat, b: CGFloat) in CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        let sky = CGGradient(colorsSpace: space, colors: [
            color(0.98, 0.78, 0.40), color(0.95, 0.45, 0.35), color(0.55, 0.22, 0.50), color(0.12, 0.10, 0.32),
        ] as CFArray, locations: [0, 0.3, 0.62, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: s * 0.35), end: CGPoint(x: 0, y: s), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

        let sun = CGGradient(colorsSpace: space, colors: [
            color(1, 0.97, 0.82), CGColor(srgbRed: 1, green: 0.8, blue: 0.5, alpha: 0),
        ] as CFArray, locations: [0.3, 1])!
        let sunCenter = CGPoint(x: s * 0.80, y: s * 0.64)
        context.drawRadialGradient(sun, startCenter: sunCenter, startRadius: 0, endCenter: sunCenter, endRadius: s * 0.20, options: [])

        // Ranges, far to near, each darker than the last.
        let ranges: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
            (0.47, 0.09, 1.3, color(0.42, 0.18, 0.40)),
            (0.38, 0.11, 2.1, color(0.27, 0.12, 0.31)),
            (0.27, 0.12, 3.4, color(0.13, 0.07, 0.20)),
        ]
        for (base, height, phase, shade) in ranges {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            for step in 0...80 {
                let x = CGFloat(step) / 80
                let ridge = sin(x * 9 + phase) * 0.5 + sin(x * 23 + phase * 2) * 0.28 + sin(x * 51 + phase * 3) * 0.12
                path.addLine(to: CGPoint(x: x * s, y: (base + ridge * height) * s))
            }
            path.addLine(to: CGPoint(x: s, y: 0))
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(shade)
            context.fillPath()
        }
        let url = work.appendingPathComponent("Sunset.png")
        try DesignComposer.writePNG(context.makeImage()!, to: url)
        return url.path
    }

    /// The real traced curve from the repo's Blu-ray regression test, with its published answer.
    private func realTrace() throws -> [CalibrationPoint] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("tests/DiscImageStudio.ArchitectureTests/BluRayObservedCurveRegressionTests.cs"), encoding: .utf8)
        let body = try XCTUnwrap(source.range(of: "RealTrace() => new(0,"))
        let regex = try NSRegularExpression(pattern: #"new\((-?\d+\.\d+), (-?\d+\.\d+)\)"#)
        let text = String(source[body.upperBound...])
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let points = matches.map { match -> CalibrationPoint in
            CalibrationPoint(x: Double(text[Range(match.range(at: 1), in: text)!])!, y: Double(text[Range(match.range(at: 2), in: text)!])!)
        }
        XCTAssertEqual(points.count, 31)
        return points
    }

    // MARK: The walkthrough

    func testRenderDemoFrames() async throws {
        let app = AppModel()
        app.recents = []
        app.cacheDirectoryOverride = work.appendingPathComponent("cache").path
        app.projectsDirectory = work.path
        await app.reloadPresets()
        let preview = PreviewModel()
        let burn = BurnModel()
        let calibration = CalibrationModel()

        let root = DemoRoot(demo: demo, app: app, preview: preview, burn: burn, calibration: calibration)
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        // Never ordered in, so nothing appears on screen.
        window = DemoWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Disc Image Studio"
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(frame.size)
        await pump(0.8)

        // Opening card.
        demo.card = ("Disc Image Studio for Mac", "From a picture to a disc image whose data draws that picture.\nRendered from the app's real pages and engine. The steps are scripted.")
        await pump(0.3)
        try capture(hold: 4)
        demo.card = nil

        // Home and a new project.
        try await show("Start from the home page.", hold: 2.2)
        demo.showNewProject = true
        try await show("Choose a CD, DVD or Blu-ray template. Presets cover standard and measured discs.", hold: 3.5, still: "new-project")
        demo.showNewProject = false
        let preset = try XCTUnwrap(app.catalog?.presets(for: .cd).first)
        await app.createProject(name: "Sunset", preset: preset, directory: work)
        XCTAssertNotNil(app.project, app.alert?.message ?? "")
        await pump(0.5)

        // Design: import, then place.
        try await show("Each project opens on the design surface.", hold: 2)
        var layer = DesignLayer(ProjectLayer(name: "Sunset.png", imagePath: try makeArtwork(), scale: 1))
        XCTAssertTrue(layer.loadImage(contentOuterRadiusMm: app.project!.geometry.outerRadiusMm))
        app.layers = [layer]
        app.selectedLayerID = layer.id
        app.scheduleComposite()
        try await wait("the first tone preview") { app.tonePreview != nil && app.tonePreviewStatus == "Live preview" }
        try await show("Import a picture. The panel on the right shows what the disc will really look like.", hold: 3.2)

        let gifStart = frameList.count
        demo.caption = "Drag, scale and rotate layers directly on the disc."
        let id = layer.id
        let motions: [(Double, Double, Double, Double)] = [(1, 0, 0, 0), (1.12, -5, 6, 0), (1.12, -5, 6, -14), (1.12, 2, -2, 0), (1.05, 0, 0, 0)]
        for pair in zip(motions, motions.dropFirst()) {
            for step in 1...18 {
                let raw = Double(step) / 18
                let t = raw * raw * (3 - 2 * raw)
                app.updateLayer(id) {
                    $0.scale = pair.0.0 + (pair.1.0 - pair.0.0) * t
                    $0.translateXMm = pair.0.1 + (pair.1.1 - pair.0.1) * t
                    $0.translateYMm = pair.0.2 + (pair.1.2 - pair.0.2) * t
                    $0.rotationDeg = pair.0.3 + (pair.1.3 - pair.0.3) * t
                }
                await pump(0.03)
                try capture()
            }
        }
        // The composite is debounced, so the render it triggers hasn't begun yet.
        await pump(0.7)
        try await wait("the placed design's preview") { app.tonePreviewStatus == "Live preview" }
        try await show("The preview follows once you let go.", hold: 2, still: "design")

        // Tone, using the real engine at each step.
        demo.caption = "Tone settings are real engine renders: less dither gives a harder image."
        for dither in [0.5, 0.25, 0.0] {
            app.updateProject { $0.tone?.ditherStrength = dither }
            try await wait("tone at \(dither)") { app.tonePreviewStatus == "Live preview" }
            try capture(hold: 0.9)
        }
        demo.caption = "More dither brings the midtones back."
        for dither in [0.5, 0.75, 1.0, 0.8] {
            app.updateProject { $0.tone?.ditherStrength = dither }
            try await wait("tone at \(dither)") { app.tonePreviewStatus == "Live preview" }
            try capture(hold: 0.7)
        }
        gifRange = gifStart..<frameList.count

        // Preview, including a measured disc that differs from the design.
        app.workspace = .preview
        await pump(0.4)
        try await wait("the projection") { !preview.isRendering && preview.image != nil }
        try await show("Preview projects the design through the disc's spiral track.", hold: 3.2, still: "preview")
        preview.measured.innerRadiusMm += 1.6
        preview.measured.outerRadiusMm += 0.4
        preview.refresh(app: app, debounce: false)
        try await wait("the shifted projection") { !preview.isRendering }
        try await show("Enter a real disc's measured radii, and a mismatch shows up before you waste a disc.", hold: 3.5)
        preview.resetMeasured(app.project!)
        preview.refresh(app: app, debounce: false)
        try await wait("the reset projection") { !preview.isRendering }

        // Export: a real, full-size generation with real progress.
        app.workspace = .export
        await pump(0.4)
        try await show("Export writes WAV + CUE, RAW or ISO files for burning.", hold: 2.6)
        demo.caption = "A full 80-minute CD track, generated by the engine with live progress and cancel."
        let generation = Task { await app.generate() }
        try await wait("the job to start") { app.job != nil }
        try await wait("some progress") { (app.job?.fraction ?? 0) > 0.25 }
        try await captureStill("export")
        var nextFraction = 0.0
        while app.job != nil {
            if let fraction = app.job?.fraction, fraction >= nextFraction {
                try capture(hold: 0.3)
                nextFraction = fraction + 0.07
            }
            await pump(0.05)
        }
        await generation.value
        XCTAssertNil(app.alert, app.alert?.message ?? "")
        let artifact = try XCTUnwrap(app.lastArtifactPath)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: artifact)[.size] as? Int64, preset.geometry.sectors * 2352 + 44)
        try await show("Done: a real 845 MB audio track and its CUE file.", hold: 2.4)

        // Read-back of that exact file.
        preview.mode = .readback
        preview.artifactPath = artifact
        app.workspace = .preview
        await pump(0.4)
        preview.refresh(app: app, debounce: false)
        try await wait("the read-back") { !preview.isRendering && preview.status.hasPrefix("File read-back") }
        XCTAssertTrue(preview.status.hasPrefix("File read-back"), preview.status)
        try await show("Read-back decodes the generated file itself, to check what will reach the disc.", hold: 3.6, still: "readback")

        // Calibration with a real traced curve and its published answer.
        preview.mode = .projection
        let session = work.appendingPathComponent("demo.calibration.json")
        let runner = try app.requireRunner()
        let created = try await runner.json(CalibrationSessionInfo.self, [
            "gui-calibration-create", "--session", session.path, "--family", "bd",
            "--r0", "23.9885", "--r1", "58.022875", "--total-sectors", "12219392",
        ])
        try await calibration.install(created, app: app)
        calibration.autoRange = false
        calibration.radiusRangeMm = 0.5
        calibration.fitDvdPitch = false
        app.workspace = .calibration
        calibration.statusMessage = "Target created. Generate it and burn it, then photograph the disc."
        await pump(0.4)
        try await show("Calibration measures a real disc. Start by burning this known target.", hold: 3)

        // Stand-in for a photo of the burned disc.
        let target = app.cacheDirectory.appendingPathComponent("calibration-target-\(created.id.prefix(8)).png")
        let targetData = try Data(contentsOf: target)
        calibration.setPhoto(file: target, base64: targetData.base64EncodedString())
        calibration.suggestOutlines()
        calibration.step = .photo
        calibration.statusMessage = "Drag the cyan points onto the disc's outer edge, and the orange points onto the centre hole's edge."
        await pump(0.3)
        try await show("Import a photo of the burned disc. A rendered target stands in for one here.", hold: 2.6)

        let width = calibration.photoPixelSize.width, height = calibration.photoPixelSize.height
        let startOuter = calibration.outerPoints, startHole = calibration.holePoints
        let ring = { (radius: Double, index: Int) -> CalibrationPoint in
            let angle = -Double.pi / 2 + 2 * .pi * Double(index) / 8
            return CalibrationPoint(x: (width - 1) / 2 + radius * cos(angle), y: (height - 1) / 2 + radius * sin(angle))
        }
        let outerRadius = (width - 1) / 2 - 4
        let holeRadius = outerRadius * 7.5 / 60
        demo.caption = "Drag the outlines onto the disc's edges, so its perspective can be corrected."
        for step in 1...24 {
            let t = Double(step) / 24
            for index in 0..<8 {
                let goalOuter = ring(outerRadius, index), goalHole = ring(holeRadius, index)
                calibration.outerPoints[index] = CalibrationPoint(x: startOuter[index].x + (goalOuter.x - startOuter[index].x) * t, y: startOuter[index].y + (goalOuter.y - startOuter[index].y) * t)
                calibration.holePoints[index] = CalibrationPoint(x: startHole[index].x + (goalHole.x - startHole[index].x) * t, y: startHole[index].y + (goalHole.y - startHole[index].y) * t)
            }
            await pump(0.03)
            try capture()
        }
        try capture(hold: 1.2)
        calibration.rectify(app: app)
        try await wait("the photo correction") { !calibration.isBusy && calibration.rectified != nil }

        demo.caption = "Then trace one curve from the inside out. These are real points from the repo's test data."
        for point in try realTrace() {
            calibration.addTracePoint(point)
            await pump(0.03)
            try capture(hold: 0.09)
        }
        try capture(hold: 1)
        calibration.solve(app: app)
        try await wait("the fit") { !calibration.isBusy && calibration.outcome != nil }
        let candidate = try XCTUnwrap(calibration.selectedCandidate, calibration.statusMessage)
        // The answer published by the repo's own regression test for this curve.
        XCTAssertEqual(candidate.parameters.innerRadiusMm, 23.988236631852867, accuracy: 5e-7)
        XCTAssertEqual(candidate.parameters.outerRadiusMm, 58.02322629697187, accuracy: 5e-7)
        calibration.contourConfirmed = true
        try await show("The engine fits the disc's real geometry. Check the orange curve, then apply it.", hold: 4.2, still: "calibration")

        // Burn.
        burn.sourcePath = artifact
        app.workspace = .burn
        await pump(1.2)
        try await show("Burning goes through macOS's own tools. It's experimental, and isn't run in this demo.", hold: 3.6, still: "burn")

        // Closing card.
        demo.caption = nil
        app.workspace = .home
        demo.card = ("See your own design", "Build it with scripts/build-app.sh.\nThis demo was rendered off-screen from the app's real pages, not recorded from a live session.")
        await pump(0.3)
        try capture(hold: 4)

        // Every warning shown should have reached English through the catalogs.
        for warning in calibration.outcome?.warnings ?? [] {
            XCTAssertFalse(app.text.translate(warning).unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, warning)
        }
        XCTAssertNil(app.alert, app.alert?.message ?? "")

        try concatFile(frameList[...]).write(to: frames.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        let range = try XCTUnwrap(gifRange)
        try concatFile(frameList[range]).write(to: frames.appendingPathComponent("gif.txt"), atomically: true, encoding: .utf8)
        print("Rendered \(frameList.count) frames, \(frameList.map(\.hold).reduce(0, +)) seconds of video.")
    }
}
