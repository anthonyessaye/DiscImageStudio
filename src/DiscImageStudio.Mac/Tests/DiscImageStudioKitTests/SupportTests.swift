import XCTest
@testable import DiscImageStudioKit

final class CommandBuilderTests: XCTestCase {
    private func settings(_ family: DiscFamily, dataDirectory: String = "", label: String = "") -> DiscJobSettings {
        DiscJobSettings(
            family: family,
            geometry: ProjectGeometry(innerRadiusMm: 24.5, outerRadiusMm: 56.8, sectors: 359_849, pitchLinear: 0.001),
            tone: ToneProfile(ditherStrength: 0.75, levels: 4, brightness: -3, srgbLinearization: true),
            invertMapping: true,
            outputs: ProjectOutputs(outputPath: "/o/out", writeCue: false, dataDirectory: dataDirectory, volumeLabel: label, interleave: true, filesAtOuterRing: true)
        )
    }

    private func value(_ arguments: [String], _ key: String) -> String? {
        arguments.firstIndex(of: key).map { arguments[$0 + 1] }
    }

    func testCdAudioCarriesInterleaveAndCueButNoFileOptions() {
        let a = CommandBuilder.generate(settings(.cd), compositePath: "/c.png")
        XCTAssertEqual(a.first, "cd-generate")
        XCTAssertEqual(value(a, "--sectors"), "359849")
        XCTAssertEqual(value(a, "--tone-levels"), "4")
        XCTAssertEqual(value(a, "--cue"), "false")
        XCTAssertEqual(value(a, "--interleave"), "true")
        XCTAssertNil(value(a, "--data-dir"))
    }

    func testCdWithFilesBecomesADataImage() {
        let a = CommandBuilder.generate(settings(.cd, dataDirectory: "/files"), compositePath: "/c.png")
        XCTAssertEqual(value(a, "--data-dir"), "/files")
        XCTAssertEqual(value(a, "--file-position"), "outer")
        XCTAssertEqual(value(a, "--volume-label"), "CD_IMAGE")
        XCTAssertNil(value(a, "--cue"))
    }

    func testDvdAndBluRayForceTwoToneLevelsAndUseTheirDefaultLabels() {
        let dvd = CommandBuilder.generate(settings(.dvd), compositePath: "/c.png")
        XCTAssertEqual(dvd.first, "solve")
        XCTAssertEqual(value(dvd, "--tone-levels"), "2")
        XCTAssertEqual(value(dvd, "--volume-label"), "DISC_IMAGE")
        XCTAssertEqual(value(dvd, "--fill-sectors"), "359849")
        XCTAssertEqual(value(dvd, "--pitch-linear"), "0.001")

        let bd = CommandBuilder.generate(settings(.bd), compositePath: "/c.png")
        XCTAssertEqual(bd.first, "bd-generate")
        XCTAssertEqual(value(bd, "--tone-levels"), "2")
        XCTAssertEqual(value(bd, "--volume-label"), "BD_IMAGE")
        XCTAssertEqual(value(bd, "--invert"), "true")
    }

    func testDvdWithFilesDoesNotFillTheWholeDisc() {
        let a = CommandBuilder.generate(settings(.dvd, dataDirectory: "/files", label: "MINE"), compositePath: "/c.png")
        XCTAssertNil(value(a, "--fill-sectors"))
        XCTAssertEqual(value(a, "--data-dir"), "/files")
        XCTAssertEqual(value(a, "--volume-label"), "MINE")
    }

    func testNumbersKeepFullPrecision() {
        XCTAssertEqual(Double(CommandBuilder.number(23.991460627731737)), 23.991460627731737)
        XCTAssertEqual(Double(CommandBuilder.number(-3.9256854319227684E-05)), -3.9256854319227684E-05)
    }

    func testCdReadbackStepDependsOnTrackKind() {
        let s = settings(.cd)
        let measured = MeasuredGeometry(geometry: s.geometry)
        let audio = CommandBuilder.readback(s, measured: measured, artifactPath: "/t.wav", outputPath: "/o.png", size: 900, samplesPerSector: 16)
        XCTAssertEqual(value(audio, "--byte-step"), "147")
        XCTAssertEqual(value(audio, "--deinterleave"), "true")
        let data = CommandBuilder.readback(s, measured: measured, artifactPath: "/t.ISO", outputPath: "/o.png", size: 900, samplesPerSector: 16)
        XCTAssertEqual(value(data, "--byte-step"), "128")
        XCTAssertNil(value(data, "--deinterleave"))
    }

    func testDvdProjectionPassesTheDrawingRange() {
        let s = settings(.dvd)
        let a = CommandBuilder.projection(s, measured: MeasuredGeometry(geometry: s.geometry), sourcePath: "/s.png", outputPath: "/o.png",
                                          size: 512, samplesPerSector: 8, drawing: (start: 32, end: 1032))
        XCTAssertEqual(value(a, "--lba"), "32")
        XCTAssertEqual(value(a, "--fill-sectors"), "1000")
    }
}

final class EngineTextTests: XCTestCase {
    private func catalog(_ json: String) throws -> EngineText {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try json.write(to: directory.appendingPathComponent("c.json"), atomically: true, encoding: .utf8)
        return EngineText(catalogDirectories: [directory])
    }

    func testTranslatesExactAndFormattedMessages() throws {
        let text = try catalog(#"""
        {"你好。": {"zh-CN": "你好。", "en": "Hello."},
         "需要 {0:N0} 字节，实际 {1:N0}。": {"en": "Need {0:N0} bytes, found {1:N0}."}}
        """#)
        XCTAssertEqual(text.translate("你好。"), "Hello.")
        XCTAssertEqual(text.translate("需要 1,024 字节，实际 7。"), "Need 1,024 bytes, found 7.")
    }

    func testLeavesUnknownMessagesAlone() throws {
        XCTAssertEqual(try catalog("{}").translate("未知"), "未知")
    }
}

final class BurnServiceTests: XCTestCase {
    /// Real `hdiutil burn -list` output, including the path's spaces and trailing tab.
    private let driveList = """
    TEAC DV-W28S-VT via USB (DRDeviceSupportLevelUnsupported)
    \tIOService:/AppleARMPE/USB2.0 Hub@01100000/IODVDServices\t
    PIONEER BD-RW BDR-XD07 via USB (DRDeviceSupportLevelFull)
    \tIOService:/AppleARMPE/second/IODVDServices\t
    """

    func testParsesDriveList() {
        let devices = BurnService.parseDeviceList(driveList)
        XCTAssertEqual(devices.map(\.index), [1, 2])
        XCTAssertEqual(devices.map(\.name), ["TEAC DV-W28S-VT", "PIONEER BD-RW BDR-XD07"])
        XCTAssertEqual(devices[0].servicePath, "IOService:/AppleARMPE/USB2.0 Hub@01100000/IODVDServices")
    }

    func testEmptyDriveList() {
        XCTAssertEqual(BurnService.parseDeviceList(""), [])
    }

    func testParsesPuppetStrings() {
        XCTAssertEqual(BurnService.parseBurnLine("PERCENT:50.0"), .progress(0.5))
        XCTAssertEqual(BurnService.parseBurnLine("PERCENT:-1"), .progress(nil))
        XCTAssertEqual(BurnService.parseBurnLine("MESSAGE:Writing"), .message("Writing"))
        XCTAssertNil(BurnService.parseBurnLine("  "))
    }

    func testAudioBurnPutsTheFolderLast() {
        XCTAssertEqual(BurnService.audioBurnArguments(folder: "/f", speed: 4, testBurn: true),
                       ["burn", "-audio", "-speed", "4", "-test", "/f"])
    }
}
