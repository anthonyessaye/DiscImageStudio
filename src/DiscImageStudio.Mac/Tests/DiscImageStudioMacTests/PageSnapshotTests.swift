import AppKit
import DiscImageStudioKit
import SwiftUI
import XCTest
@testable import DiscImageStudioMac

/// Renders each page into an off-screen window, in this test's own process, and writes PNGs
/// for inspection. It touches neither the display nor a running copy of the app.
/// Needs DISC_IMAGE_STUDIO_CLI, and DISC_IMAGE_STUDIO_SNAPSHOTS for where to put the images.
@MainActor
final class PageSnapshotTests: XCTestCase {
    private var output: URL!
    private var work: URL!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf((environment["DISC_IMAGE_STUDIO_CLI"] ?? "").isEmpty, "Set DISC_IMAGE_STUDIO_CLI.")
        try XCTSkipIf((environment["DISC_IMAGE_STUDIO_SNAPSHOTS"] ?? "").isEmpty, "Set DISC_IMAGE_STUDIO_SNAPSHOTS.")
        output = URL(fileURLWithPath: environment["DISC_IMAGE_STUDIO_SNAPSHOTS"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    private func pump(_ seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
    }

    private func snapshot<V: View>(_ view: V, name: String, settle: Double = 0.8) async throws {
        let host = NSHostingView(rootView: view.frame(width: 1200, height: 760)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 760)
        // Never ordered in, so nothing appears on screen.
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        await pump(settle)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
        window.close()
    }

    private func picture() throws -> String {
        let size = 800
        let context = CGContext(data: nil, width: size, height: size / 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0..<8 {
            context.setFillColor(CGColor(red: Double(i) / 7, green: 0.4, blue: 1 - Double(i) / 7, alpha: 1))
            context.fill(CGRect(x: i * 100, y: 0, width: 100, height: size / 2))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 300, y: 100, width: 200, height: 200))
        let url = work.appendingPathComponent("picture.png")
        try DesignComposer.writePNG(context.makeImage()!, to: url)
        return url.path
    }

    private func makeApp(family: DiscFamily) async throws -> AppModel {
        let app = AppModel()
        app.cacheDirectoryOverride = work.appendingPathComponent("cache").path
        await app.reloadPresets()
        let preset = try XCTUnwrap(app.catalog?.presets(for: family).first)
        await app.createProject(name: "Snapshot \(family.label) \(UUID().uuidString.prefix(6))", preset: preset, directory: work)
        XCTAssertNotNil(app.project, app.alert?.message ?? "no project")
        var layer = DesignLayer(ProjectLayer(name: "picture.png", imagePath: try picture(), rotationDeg: 20, scale: 0.8))
        XCTAssertTrue(layer.loadImage(contentOuterRadiusMm: app.project!.geometry.outerRadiusMm))
        app.layers = [layer]
        app.selectedLayerID = layer.id
        app.scheduleComposite()
        await pump(3)
        XCTAssertNotNil(app.compositePath, "the composite should have rendered")
        return app
    }

    func testRenderEveryPage() async throws {
        for family in DiscFamily.allCases {
            let app = try await makeApp(family: family)
            await pump(family == .cd ? 3 : 2)
            XCTAssertNotNil(app.tonePreview, "\(family.label) tone preview: \(app.tonePreviewStatus)")
            let tag = family.rawValue
            try await snapshot(DesignView().environmentObject(app), name: "\(tag)-design")
            try await snapshot(ExportView().environmentObject(app), name: "\(tag)-export")

            let preview = PreviewModel()
            try await snapshot(PreviewView(model: preview).environmentObject(app), name: "\(tag)-preview", settle: 6)
            XCTAssertNotNil(preview.image, "\(family.label) preview: \(preview.status)")
            XCTAssertNil(app.alert, app.alert?.message ?? "")
        }

        let app = try await makeApp(family: .cd)
        app.recents = [RecentProject(path: "/Users/me/Discs/Sample.discproj", name: "Sample", family: .dvd)]
        try await snapshot(HomeView().environmentObject(app), name: "home")
        try await snapshot(NewProjectSheet().environmentObject(app), name: "new-project")
        try await snapshot(ProjectSettingsSheet().environmentObject(app), name: "project-settings")
        try await snapshot(BurnView(model: BurnModel()).environmentObject(app), name: "burn", settle: 2)
        try await snapshot(SettingsView().environmentObject(app), name: "settings")
        try await snapshot(ShellView().environmentObject(app), name: "shell")

        let calibration = CalibrationModel()
        try await snapshot(CalibrationView(model: calibration).environmentObject(app), name: "calibration-empty")

        // The later steps, with a real photo stand-in, outlines and trace.
        let photoFile = URL(fileURLWithPath: try picture())
        calibration.photo = NSImage(contentsOf: photoFile)
        calibration.photoPixelSize = CGSize(width: 800, height: 400)
        calibration.suggestOutlines()
        calibration.step = .photo
        try await snapshot(CalibrationView(model: calibration).environmentObject(app), name: "calibration-photo")

        calibration.rectified = NSImage(contentsOf: photoFile)
        calibration.rectifiedRadiusMm = 63
        for i in 0..<8 {
            calibration.addTracePoint(CalibrationPoint(x: 26 + Double(i) * 3.5, y: Double(i) * 1.5))
        }
        XCTAssertEqual(calibration.tracePoints.count, 8)
        calibration.step = .trace
        try await snapshot(CalibrationView(model: calibration).environmentObject(app), name: "calibration-trace")
    }

    func testThemeChangeIsPublished() async throws {
        let app = AppModel()
        var fired = false
        let token = app.objectWillChange.sink { fired = true }
        let original = app.themeRaw
        app.themeRaw = original == "dark" ? "light" : "dark"
        XCTAssertTrue(fired)
        app.themeRaw = original
        token.cancel()
    }
}
