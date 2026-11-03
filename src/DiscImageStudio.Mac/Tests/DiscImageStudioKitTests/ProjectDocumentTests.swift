import XCTest
@testable import DiscImageStudioKit

final class ProjectDocumentTests: XCTestCase {
    /// Shaped like a file written by the Windows app, including its seven-digit timestamps.
    private let windowsProject = """
    {
      "schemaVersion": 2,
      "name": "Sample",
      "discFamily": "dvd",
      "geometry": {
        "innerRadiusMm": 24,
        "outerRadiusMm": 58,
        "sectors": 2295104,
        "pitchLinear": 0.74,
        "pitchQuadratic": 0,
        "pitchCubic": 0
      },
      "layers": [
        {
          "id": "abc",
          "name": "Layer",
          "imagePath": "/tmp/picture.png",
          "visible": true,
          "translateXMm": 1.5,
          "translateYMm": -2,
          "rotationDeg": 45,
          "scale": 1.25
        }
      ],
      "outputs": {
        "outputPath": "/tmp/out.iso",
        "writeCue": false,
        "dataDirectory": "",
        "volumeLabel": "DVD_IMAGE",
        "interleave": true
      },
      "calibrationSessionPath": null,
      "thumbnailPngBase64": null,
      "createdUtc": "2026-11-03T15:13:00.1234567+00:00",
      "modifiedUtc": "2026-11-03T15:14:00.1234567+00:00",
      "tone": { "ditherStrength": 0.75, "levels": 2, "brightness": 0, "srgbLinearization": true }
    }
    """

    private func decode(_ json: String) throws -> ProjectDocument {
        try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8))
    }

    func testReadsWindowsProject() throws {
        let project = try decode(windowsProject)
        XCTAssertEqual(project.discFamily, .dvd)
        XCTAssertEqual(project.geometry.sectors, 2_295_104)
        XCTAssertEqual(project.layers.first?.scale, 1.25)
        XCTAssertEqual(project.outputs.filesAtOuterRing, false)
        XCTAssertEqual(project.tone?.srgbLinearization, true)
        XCTAssertNil(project.bluRay)
        XCTAssertEqual(project.createdUtc, "2026-11-03T15:13:00.1234567+00:00")
    }

    func testSaveAndLoadPreservesEverything() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".discproj")
        defer { try? FileManager.default.removeItem(at: url) }

        let project = try decode(windowsProject)
        try project.save(to: url)
        XCTAssertEqual(try ProjectDocument.load(from: url), project)
    }

    func testIgnoresLegacyImageProcessingAndUpgradesSchemaOnSave() throws {
        let legacy = windowsProject
            .replacingOccurrences(of: "\"schemaVersion\": 2,", with: "\"schemaVersion\": 1,\n\"imageProcessing\": {},")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".discproj")
        defer { try? FileManager.default.removeItem(at: url) }

        try decode(legacy).save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("imageProcessing"))
        XCTAssertEqual(try ProjectDocument.load(from: url).schemaVersion, 2)
    }

    func testAcceptsAnyFamilyCasingAndRejectsUnknownFamilies() throws {
        XCTAssertEqual(
            try decode(windowsProject.replacingOccurrences(of: "\"dvd\"", with: "\"DVD\"")).discFamily,
            .dvd
        )
        XCTAssertThrowsError(try decode(windowsProject.replacingOccurrences(of: "\"dvd\"", with: "\"hddvd\"")))
    }
}
