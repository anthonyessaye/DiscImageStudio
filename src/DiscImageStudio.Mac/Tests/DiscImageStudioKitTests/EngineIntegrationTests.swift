import CoreGraphics
import XCTest
@testable import DiscImageStudioKit

/// Runs the app's command building and response decoding against the real engine. Set
/// DISC_IMAGE_STUDIO_CLI to the built CLI to enable these; without it they are skipped.
final class EngineIntegrationTests: XCTestCase {
    private var runner: CLIRunner!
    private var directory: URL!

    override func setUpWithError() throws {
        let path = ProcessInfo.processInfo.environment["DISC_IMAGE_STUDIO_CLI"] ?? ""
        try XCTSkipIf(path.isEmpty, "Set DISC_IMAGE_STUDIO_CLI to run engine tests.")
        runner = CLIRunner(executableURL: URL(fileURLWithPath: path))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    /// A black disc on white, off-centre, so a preview that ignored the picture would show.
    private func writePicture() throws -> String {
        let size = 512
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 280, y: 280, width: 200, height: 200))
        let url = directory.appendingPathComponent("picture.png")
        try DesignComposer.writePNG(context.makeImage()!, to: url)
        return url.path
    }

    private func document(_ family: DiscFamily, _ geometry: ProjectGeometry) -> ProjectDocument {
        ProjectDocument(
            name: "Test", discFamily: family, geometry: geometry,
            layers: [ProjectLayer(name: "Layer", imagePath: "/tmp/p.png", translateXMm: 1, rotationDeg: 30, scale: 1.2)],
            outputs: ProjectOutputs(outputPath: "/tmp/out", volumeLabel: "LABEL"),
            createdUtc: "2026-11-03T15:13:00.1234567+00:00",
            modifiedUtc: ISO8601DateFormatter().string(from: Date()),
            tone: .photo,
            bluRay: family == .bd ? ProjectBluRaySettings(invertMapping: true) : nil
        )
    }

    private var geometries: [(DiscFamily, ProjectGeometry)] {
        [
            (.cd, ProjectGeometry(innerRadiusMm: 24.5, outerRadiusMm: 24.9, sectors: 2000)),
            (.dvd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 24.1, sectors: 1600)),
            (.bd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 24.1, sectors: 6400)),
        ]
    }

    /// True if the PNG shows both dark and light disc area, so it isn't blank.
    private func assertHasContent(_ file: String, line: UInt = #line) throws {
        let image = try XCTUnwrap(DesignComposer.loadImage(path: file), "no image at \(file)", line: line)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertGreaterThan(Set(pixels).count, 1, "\(file) is a single flat colour", line: line)
    }

    // MARK: File compatibility

    func testEngineAcceptsProjectsSavedByTheMacAppForEveryFamily() async throws {
        for (family, geometry) in [
            (DiscFamily.cd, ProjectGeometry(innerRadiusMm: 24.5, outerRadiusMm: 56.8, sectors: 359_849)),
            (.dvd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 2_295_104)),
            (.bd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 12_219_392)),
        ] {
            let file = directory.appendingPathComponent("\(family.rawValue).discproj")
            try document(family, geometry).save(to: file)
            _ = try await runner.capture(["gui-project-validate", "--input", file.path])
            XCTAssertEqual(try ProjectDocument.load(from: file).discFamily, family)
        }
    }

    func testEngineRejectsAnInvalidProjectWithItsOwnMessage() async throws {
        let file = directory.appendingPathComponent("bad.discproj")
        try document(.dvd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 15)).save(to: file)
        do {
            _ = try await runner.capture(["gui-project-validate", "--input", file.path])
            XCTFail("A DVD sector count that isn't a multiple of 16 should be rejected.")
        } catch let failure as CLIFailure {
            XCTAssertTrue(failure.message.contains("16"), failure.message)
            XCTAssertFalse(failure.message.hasPrefix("error:"))
        }
    }

    func testPresetsDecodeForEveryFamilyWithPlausibleGeometry() async throws {
        let catalog = try await runner.json(DiscPresetCatalog.self, ["gui-presets", "--user-file", path("missing.json")])
        for family in DiscFamily.allCases {
            let presets = catalog.presets(for: family)
            XCTAssertFalse(presets.isEmpty, family.label)
            for preset in presets {
                XCTAssertGreaterThan(preset.geometry.sectors, 0, preset.id)
                XCTAssertGreaterThan(preset.geometry.outerRadiusMm, preset.geometry.innerRadiusMm, preset.id)
            }
        }
    }

    func testUserPresetRoundTripsAndKeepsPrecision() async throws {
        let file = path("presets.json")
        _ = try await runner.capture(["gui-preset-save", "--user-file", file, "--id", "mine", "--name", "My disc",
                                      "--family", "dvd", "--sectors", "2295104", "--r0", "23.991460627731737", "--r1", "57.9",
                                      "--pitch-linear", "-3.9256854319227684E-05"])
        let catalog = try await runner.json(DiscPresetCatalog.self, ["gui-presets", "--user-file", file])
        let preset = try XCTUnwrap(catalog.presets(for: .dvd).first { $0.id == "mine" })
        XCTAssertEqual(preset.geometry.innerRadiusMm, 23.991460627731737)
        XCTAssertEqual(preset.geometry.pitchLinear, -3.9256854319227684E-05)
    }

    // MARK: Generation and previews

    func testGenerateAndPreviewEveryFamilyWithTheAppsArguments() async throws {
        let picture = try writePicture()
        for (family, geometry) in geometries {
            let name = family.rawValue
            let output = path(family == .cd ? "\(name).wav" : "\(name).iso")
            let settings = DiscJobSettings(family: family, geometry: geometry, tone: .photo, invertMapping: false,
                                           outputs: ProjectOutputs(outputPath: output, volumeLabel: ""))
            let measured = MeasuredGeometry(geometry: geometry)

            _ = try await runner.capture(CommandBuilder.generate(settings, compositePath: picture))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output), "\(name) output")

            let tone = path("\(name)-tone.png")
            _ = try await runner.capture(CommandBuilder.tonePreview(settings, sourcePath: picture, outputPath: tone))
            try assertHasContent(tone)

            let projection = path("\(name)-projection.png")
            _ = try await runner.capture(CommandBuilder.projection(settings, measured: measured, sourcePath: picture, outputPath: projection, size: 256, samplesPerSector: 8, drawing: nil))
            try assertHasContent(projection)

            let info = try await runner.json(ArtifactInfo.self, ["gui-artifact-info", "--family", name, "--input", output])
            XCTAssertTrue(info.hasSidecar, "\(name) sidecar")

            let readback = path("\(name)-readback.png")
            _ = try await runner.capture(CommandBuilder.readback(settings, measured: measured, artifactPath: output, outputPath: readback, size: 256, samplesPerSector: 8))
            try assertHasContent(readback)
        }
    }

    func testFilesOnDiscProducePlansAndOverlayForEveryFamily() async throws {
        let picture = try writePicture()
        let files = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try "hello".write(to: files.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        for (family, geometry) in [
            (DiscFamily.cd, ProjectGeometry(innerRadiusMm: 24.5, outerRadiusMm: 24.9, sectors: 2000)),
            (.dvd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 24.1, sectors: 1600)),
            (.bd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 24.1, sectors: 6400)),
        ] {
            let settings = DiscJobSettings(family: family, geometry: geometry, tone: .photo, invertMapping: false,
                                           outputs: ProjectOutputs(outputPath: path("\(family.rawValue)-files.iso"), dataDirectory: files.path, volumeLabel: "", filesAtOuterRing: false))
            let measured = MeasuredGeometry(geometry: geometry)
            let plan = try await runner.json(DrawingPlan.self, CommandBuilder.drawingPlan(settings))
            XCTAssertGreaterThan(plan.start, 0, "\(family.label) files go before the picture")
            XCTAssertLessThanOrEqual(plan.end, geometry.sectors)

            let preview = path("\(family.rawValue)-files.png")
            _ = try await runner.capture(CommandBuilder.projection(settings, measured: measured, sourcePath: picture, outputPath: preview, size: 256, samplesPerSector: 8, drawing: (plan.start, plan.end)))
            _ = try await runner.capture(CommandBuilder.overlay(settings, measured: measured, path: preview, drawing: (plan.start, plan.end)))
            try assertHasContent(preview)

            _ = try await runner.capture(CommandBuilder.generate(settings, compositePath: picture))
            let info = try await runner.json(ArtifactInfo.self, ["gui-artifact-info", "--family", family.rawValue, "--input", settings.outputs.outputPath])
            XCTAssertTrue(info.hasFileRegion, "\(family.label) file region is recorded")
            XCTAssertEqual(info.drawingStart, plan.start, family.label)
        }
    }

    func testProgressArrivesAsDataDuringGeneration() async throws {
        let picture = try writePicture()
        let settings = DiscJobSettings(family: .cd, geometry: ProjectGeometry(innerRadiusMm: 24.5, outerRadiusMm: 24.9, sectors: 2000), tone: .photo, invertMapping: false,
                                       outputs: ProjectOutputs(outputPath: path("progress.wav"), volumeLabel: ""))
        let job = try runner.start(CommandBuilder.generate(settings, compositePath: picture))
        var fractions: [Double] = []
        for await event in job.events {
            if case .progress(let progress) = event, let fraction = progress.fraction { fractions.append(fraction) }
        }
        let result = await job.wait()
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions.last, 1)
    }

    func testCancellingARealJobStopsItSoonAndLeavesNoFinishedOutput() async throws {
        let picture = try writePicture()
        // A full-size Blu-ray takes far longer than this test waits.
        let output = path("cancel.iso")
        let settings = DiscJobSettings(family: .bd, geometry: ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 12_219_392), tone: .photo, invertMapping: false,
                                       outputs: ProjectOutputs(outputPath: output, volumeLabel: ""))
        let job = try runner.start(CommandBuilder.generate(settings, compositePath: picture))
        for await event in job.events {
            if case .progress = event { break }
        }
        let began = Date()
        job.cancel()
        let result = await job.wait()
        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(began), 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output), "a cancelled job must not leave a file that looks finished")
    }

    // MARK: Calibration

    func testCalibrationResponsesDecodeAcrossTheWholeWorkflow() async throws {
        let session = path("cd.calibration.json")
        let created = try await runner.json(CalibrationSessionInfo.self, [
            "gui-calibration-create", "--session", session, "--family", "cd", "--r0", "24.5", "--r1", "56.8", "--sectors", "359849",
        ])
        XCTAssertEqual(created.parameters.family, .cd)
        XCTAssertEqual(created.parameters.sectors, 359_849)
        XCTAssertNil(created.photo)

        let target = path("target.png")
        _ = try await runner.capture(["gui-calibration-render", "--session", session, "--output", target, "--size", "300"])
        try assertHasContent(target)

        // A real photo goes in, so the session's own validation applies to what the app sends.
        let picture = try writePicture()
        let ring = { (radius: Double) in
            (0..<8).map { i -> CalibrationPoint in
                let a = Double(i) * .pi / 4
                return CalibrationPoint(x: 256 + radius * cos(a), y: 256 + radius * sin(a))
            }
        }
        let rectifyRequest = directory.appendingPathComponent("rectify.json")
        try JSONEncoder().encode(PhotoRectifyRequest(outer: ring(220), hole: ring(28), physicalOuterRadiusMm: 60)).write(to: rectifyRequest)
        let rectified = try await runner.json(PhotoRectifyResult.self, [
            "gui-photo-rectify", "--request", rectifyRequest.path, "--input", picture, "--output", path("rectified.png"),
        ])
        XCTAssertTrue(rectified.succeeded, rectified.message)
        XCTAssertEqual(rectified.canvasRadiusMm, 63)
        try assertHasContent(path("rectified.png"))

        // Too few points: the engine must answer with a decodable failure, not an error.
        let photo = CalibrationPhoto(
            imagePngBase64: try Data(contentsOf: URL(fileURLWithPath: picture)).base64EncodedString(),
            outerBoundary: ring(220), holeBoundary: ring(28), physicalOuterRadiusMm: 60,
            rectificationConfirmed: true,
            traces: [CalibrationCrossTrace(points: [CalibrationPoint(x: 30, y: 1), CalibrationPoint(x: 40, y: 2)])]
        )
        let saveRequest = directory.appendingPathComponent("save.json")
        try JSONEncoder().encode(CalibrationSaveRequest(photo: photo, radiusRangeMm: 0.02, autoRange: true, fitDvdPitch: true)).write(to: saveRequest)
        _ = try await runner.capture(["gui-calibration-save", "--session", session, "--request", saveRequest.path])

        let outcome = try await runner.json(CalibrationFitOutcome.self, ["gui-calibration-fit", "--session", session])
        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(outcome.warnings.isEmpty)

        let reopened = try await runner.json(CalibrationSessionInfo.self, ["gui-calibration-info", "--session", session])
        XCTAssertEqual(reopened.photo?.traces.first?.points.count, 2)
        XCTAssertEqual(reopened.fitOptions?.autoRange, true)
    }

    func testCalibrationCreateWorksWithTheAppsArgumentsForEveryFamily() async throws {
        for (family, geometry) in [
            (DiscFamily.cd, ProjectGeometry(innerRadiusMm: 24.5, outerRadiusMm: 56.8, sectors: 359_849)),
            (.dvd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 2_295_104)),
            (.bd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 12_219_392)),
        ] {
            var arguments = ["gui-calibration-create", "--session", path("\(family.rawValue).calibration.json")]
                + CommandBuilder.helperGeometry(family, geometry)
            if family == .dvd { arguments += ["--sectors", String(geometry.sectors)] }
            if family == .bd { arguments += ["--invert", "false"] }
            let created = try await runner.json(CalibrationSessionInfo.self, arguments)
            XCTAssertEqual(created.parameters.family, family)
            XCTAssertEqual(created.parameters.sectors, geometry.sectors)
        }
    }

    func testCalibrationGeneratePublishesTheImageAndItsRecordTogether() async throws {
        let session = path("small.calibration.json")
        _ = try await runner.capture(["gui-calibration-create", "--session", session, "--family", "cd",
                                      "--r0", "24.5", "--r1", "25.5", "--sectors", "2000"])
        let output = path("small.wav")
        _ = try await runner.capture(["gui-calibration-generate", "--session", session, "--output", output])
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("small.calibration.json")))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".calibration-") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: Engine message translation

    func testEngineMessagesTranslateThroughTheRealCatalogs() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = EngineText(catalogDirectories: [
            root.appendingPathComponent("DiscImageStudio.App/Localization/Catalogs"),
            root.appendingPathComponent("DiscImageStudio.Mac/Catalogs"),
        ])
        XCTAssertNotEqual(text.translate("标准 80min CD"), "标准 80min CD")
        XCTAssertEqual(text.translate("DVD 的 sectors 必须是 16 的倍数。"), "A DVD's sector count must be a multiple of 16.")
        XCTAssertEqual(text.translate("蓝光 sectors 不能超过单层容量 12,219,392。"),
                       "A Blu-ray's sector count can't exceed the single-layer capacity of 12,219,392.")

        // A real engine failure, from the file through to the sentence the user reads.
        let file = directory.appendingPathComponent("bad.discproj")
        try document(.dvd, ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 15)).save(to: file)
        do {
            _ = try await runner.capture(["gui-project-validate", "--input", file.path])
            XCTFail("Expected a validation failure.")
        } catch let failure as CLIFailure {
            XCTAssertEqual(text.translate(failure.message), "A DVD's sector count must be a multiple of 16.")
        }
    }
}
