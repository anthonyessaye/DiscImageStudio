import DiscRecording
import XCTest
@testable import DiscImageStudioKit

final class DiscBurnerTests: XCTestCase {
    private func media(blank: Bool = true, free: Int64 = 2_297_888) -> DiscMedia {
        DiscMedia(mediaClass: .dvd, isBlank: blank, freeBlocks: free)
    }

    // MARK: Refusing before anything can be written

    func testRefusesWithoutADiscOrABlankDisc() {
        XCTAssertNotNil(DiscBurner.problem(media: nil, imageBytes: 2048))
        XCTAssertNotNil(DiscBurner.problem(media: media(blank: false), imageBytes: 2048))
    }

    func testRefusesAnImageThatDoesNotFit() {
        let problem = DiscBurner.problem(media: media(free: 10), imageBytes: 11 * 2048)
        XCTAssertTrue(problem?.contains("11") == true, problem ?? "")
    }

    func testRefusesAFileThatIsNotWholeSectors() {
        XCTAssertNotNil(DiscBurner.problem(media: media(), imageBytes: 2049))
        XCTAssertNotNil(DiscBurner.problem(media: media(), imageBytes: 0))
    }

    func testAcceptsAnImageThatExactlyFits() {
        XCTAssertNil(DiscBurner.problem(media: media(free: 10), imageBytes: 10 * 2048))
        // The real ISO on the real disc: 2,295,104 sectors on 2,297,888.
        XCTAssertNil(DiscBurner.problem(media: media(), imageBytes: 4_700_372_992))
    }

    // MARK: What the drive is told

    func testBurnRequiresDiscAtOnceAndClosesTheDisc() {
        let p = DiscBurner.burnProperties(media: .dvd, speed: nil, verify: true, eject: true, testBurn: false)
        XCTAssertEqual(p[DRBurnStrategyKey] as? [String], [DRBurnStrategyDVDDAO])
        XCTAssertEqual(p[DRBurnStrategyIsRequiredKey] as? Bool, true)
        XCTAssertEqual(p[DRBurnAppendableKey] as? Bool, false)
        XCTAssertEqual(p[DRBurnTestingKey] as? Bool, false)
        XCTAssertNil(p[DRBurnRequestedSpeedKey], "no speed means the drive's maximum")
    }

    func testTestBurnKeepsTheLaserOffAndSkipsVerifying() {
        let p = DiscBurner.burnProperties(media: .dvd, speed: nil, verify: true, eject: true, testBurn: true)
        XCTAssertEqual(p[DRBurnTestingKey] as? Bool, true)
        XCTAssertEqual(p[DRBurnVerifyDiscKey] as? Bool, false, "there is nothing on the disc to verify")
    }

    func testSpeedIsConvertedFromTimesToKilobytesPerSecond() {
        let p = DiscBurner.burnProperties(media: .dvd, speed: 4, verify: false, eject: false, testBurn: false)
        XCTAssertEqual((p[DRBurnRequestedSpeedKey] as? NSNumber)?.floatValue, 5540)
    }

    func testEachMediaUsesItsOwnWholeDiscStrategy() {
        XCTAssertEqual(DiscMediaClass.cd.strategy, DRBurnStrategyCDSAO)
        XCTAssertEqual(DiscMediaClass.dvd.strategy, DRBurnStrategyDVDDAO)
        XCTAssertEqual(DiscMediaClass.bd.strategy, DRBurnStrategyBDDAO)
    }

    func testDvdTrackStartsAtTheFirstSectorAsPlainData() throws {
        let p = DiscBurner.trackProperties(blocks: 2_295_104, media: .dvd)
        XCTAssertEqual((p[DRTrackLengthKey] as? DRMSF)?.sectors(), 2_295_104)
        XCTAssertEqual(p[DRBlockSizeKey] as? NSNumber, 2048)
        XCTAssertEqual(p[DRBlockTypeKey] as? NSNumber, NSNumber(value: kDRBlockTypeDVDData))
        XCTAssertEqual(p[DRTrackModeKey] as? NSNumber, NSNumber(value: kDRTrackModeDVDData))
        XCTAssertEqual((p[DRPreGapLengthKey] as? DRMSF)?.sectors(), 0, "a pre-gap would shift the picture")
    }

    // MARK: Bytes

    private func imageFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burn-\(UUID().uuidString).iso")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(bytes).write(to: url)
        return url
    }

    func testProducerReturnsTheFilesExactBytesAtAnyAddress() throws {
        let bytes = (0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let producer = try ImageTrackProducer(path: try imageFile(bytes).path)
        XCTAssertEqual(producer.byteCount, 8192)

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
        defer { buffer.deallocate() }
        // Out of order on purpose: nothing should depend on reading sequentially.
        for address in [4096, 0, 6144, 2048] {
            XCTAssertEqual(producer.read(into: buffer, length: 2048, at: UInt64(address)), 2048)
            let got = UnsafeBufferPointer(start: buffer, count: 2048).map { UInt8(bitPattern: $0) }
            XCTAssertEqual(got, Array(bytes[address..<address + 2048]), "address \(address)")
        }
    }

    func testProducerStopsAtTheEndOfTheFile() throws {
        let producer = try ImageTrackProducer(path: try imageFile([UInt8](repeating: 7, count: 4096)).path)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 8192)
        defer { buffer.deallocate() }
        XCTAssertEqual(producer.read(into: buffer, length: 8192, at: 2048), 2048)
        XCTAssertEqual(producer.read(into: buffer, length: 8192, at: 4096), 0)
    }

    func testMissingFileFailsClearly() {
        XCTAssertThrowsError(try ImageTrackProducer(path: "/no/such/file.iso"))
    }

    func testVerificationCatchesAWrongByte() throws {
        let bytes = [UInt8](repeating: 9, count: 2048)
        let producer = try ImageTrackProducer(path: try imageFile(bytes).path)
        let track: DRTrack = DRTrack(producer: producer)
        var flags: UInt32 = 0
        var disc = bytes.map { CChar(bitPattern: $0) }
        XCTAssertTrue(producer.verifyData(for: track, inBuffer: disc, length: 2048, atAddress: 0, blockSize: 2048, ioFlags: &flags))
        disc[100] = 0
        XCTAssertFalse(producer.verifyData(for: track, inBuffer: disc, length: 2048, atAddress: 0, blockSize: 2048, ioFlags: &flags))
    }

    // MARK: The real drive, without writing

    /// Set DISC_IMAGE_STUDIO_BURN_ISO to an image, with a blank disc loaded. This runs every
    /// step short of `writeLayout`, so the disc isn't touched.
    func testRealDrivePreparesWithoutWriting() throws {
        let path = ProcessInfo.processInfo.environment["DISC_IMAGE_STUDIO_BURN_ISO"] ?? ""
        try XCTSkipIf(path.isEmpty, "Set DISC_IMAGE_STUDIO_BURN_ISO to check against a real drive.")
        let prepared = try DiscBurner.prepare(imagePath: path, servicePath: nil)
        print("drive: \(prepared.device.displayName() ?? "?")  media: \(prepared.media)")
        XCTAssertTrue(prepared.media.isBlank)
        let blocks = prepared.producer.byteCount / 2048
        XCTAssertEqual(UInt64(prepared.track.length().sectors()), blocks)
        XCTAssertEqual(prepared.track.estimateLength(), prepared.producer.byteCount)
        // Pulls real data through DiscRecording's track machinery, with no burn involved.
        let megabytesPerSecond = prepared.track.testProductionSpeed(forInterval: 1) / 1024
        print("production speed: \(megabytesPerSecond) MB/s")
        XCTAssertGreaterThan(megabytesPerSecond, 11, "must outrun an 8x DVD write")
    }
}
