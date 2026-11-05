import DiscRecording
import Foundation

/// DiscRecording's C constants arrive in Swift as optional CFStrings.
private func drString(_ value: CFString?) -> String { value.map { $0 as String } ?? "" }

public enum DiscMediaClass: String, Equatable, Sendable {
    case cd = "CD"
    case dvd = "DVD"
    case bd = "Blu-ray"

    /// DiscRecording takes speeds in KB/s, while people choose them as "8x".
    var oneXKilobytesPerSecond: Float {
        switch self {
        case .cd: 176.4
        case .dvd: 1385
        case .bd: 4496
        }
    }

    var strategy: String {
        switch self {
        case .cd: DRBurnStrategyCDSAO
        case .dvd: DRBurnStrategyDVDDAO
        case .bd: DRBurnStrategyBDDAO
        }
    }
}

public struct DiscMedia: Equatable, Sendable {
    public var mediaClass: DiscMediaClass
    public var isBlank: Bool
    public var freeBlocks: Int64

    public init(mediaClass: DiscMediaClass, isBlank: Bool, freeBlocks: Int64) {
        self.mediaClass = mediaClass
        self.isBlank = isBlank
        self.freeBlocks = freeBlocks
    }
}

public struct DiscBurnFailure: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Feeds a disc image to DiscRecording byte for byte. It reads with `pread` because the
/// engine may ask for any address, and it must never block for long while the drive's
/// buffer is draining.
final class ImageTrackProducer: NSObject, DRTrackDataProduction {
    let fileDescriptor: Int32
    let byteCount: UInt64

    init(path: String) throws {
        fileDescriptor = open(path, O_RDONLY)
        guard fileDescriptor >= 0 else { throw DiscBurnFailure("Couldn't open \(path).") }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            close(fileDescriptor)
            throw DiscBurnFailure("Couldn't read the size of \(path).")
        }
        byteCount = UInt64(info.st_size)
    }

    deinit { close(fileDescriptor) }

    /// Returns the bytes read, stopping at the end of the file. Zero means nothing could be read.
    func read(into buffer: UnsafeMutablePointer<CChar>, length: UInt32, at address: UInt64) -> UInt32 {
        guard address < byteCount else { return 0 }
        let wanted = min(UInt64(length), byteCount - address)
        var done: UInt64 = 0
        while done < wanted {
            let count = pread(fileDescriptor, buffer + Int(done), Int(wanted - done), off_t(address + done))
            if count <= 0 { break }
            done += UInt64(count)
        }
        return UInt32(done)
    }

    func estimateLength(of track: DRTrack!) -> UInt64 { byteCount }
    func prepare(_ track: DRTrack!, for burn: DRBurn!, toMedia mediaInfo: [AnyHashable: Any]!) -> Bool { true }
    func cleanupTrack(afterBurn track: DRTrack!) {}

    func producePreGap(for track: DRTrack!, intoBuffer buffer: UnsafeMutablePointer<CChar>!, length bufferLength: UInt32, atAddress address: UInt64, blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> UInt32 {
        memset(buffer, 0, Int(bufferLength))
        return bufferLength
    }

    func produceData(for track: DRTrack!, intoBuffer buffer: UnsafeMutablePointer<CChar>!, length bufferLength: UInt32, atAddress address: UInt64, blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> UInt32 {
        read(into: buffer, length: bufferLength, at: address)
    }

    func prepareTrack(forVerification track: DRTrack!) -> Bool { true }

    func verifyPreGap(for track: DRTrack!, inBuffer buffer: UnsafePointer<CChar>!, length bufferLength: UInt32, atAddress address: UInt64, blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> Bool { true }

    func verifyData(for track: DRTrack!, inBuffer buffer: UnsafePointer<CChar>!, length bufferLength: UInt32, atAddress address: UInt64, blockSize: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>!) -> Bool {
        let expected = UnsafeMutablePointer<CChar>.allocate(capacity: Int(bufferLength))
        defer { expected.deallocate() }
        let count = read(into: expected, length: bufferLength, at: address)
        return count == bufferLength && memcmp(expected, buffer, Int(bufferLength)) == 0
    }

    func cleanupTrack(afterVerification track: DRTrack!) -> Bool { true }
}

/// A burn in progress. Read `events`, then `wait()` for the outcome.
public final class DiscBurnJob: @unchecked Sendable {
    public let events: AsyncStream<BurnEvent>

    private let burn: DRBurn
    private let producer: ImageTrackProducer
    private let track: DRTrack
    private let continuation: AsyncStream<BurnEvent>.Continuation
    private let queue = DispatchQueue(label: "DiscImageStudio.DiscBurnJob")
    private let finished = DispatchGroup()
    private var timer: DispatchSourceTimer?
    private var failure: String?
    private var cancelled = false

    fileprivate init(burn: DRBurn, track: DRTrack, producer: ImageTrackProducer) {
        self.burn = burn
        self.track = track
        self.producer = producer
        var streamContinuation: AsyncStream<BurnEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { streamContinuation = $0 }
        continuation = streamContinuation
    }

    fileprivate func start() {
        finished.enter()
        burn.writeLayout(track)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    private func poll() {
        guard let status = burn.status() else { return }
        let state = status[drString(kDRStatusStateKey)] as? String
        if let percent = status[drString(kDRStatusPercentCompleteKey)] as? Float {
            continuation.yield(.progress(percent >= 0 ? Double(percent) : nil))
        }
        if let state, state != lastState {
            lastState = state
            if let label = DiscBurner.label(forState: state) { continuation.yield(.message(label)) }
        }
        guard state == drString(kDRStatusStateDone) || state == drString(kDRStatusStateFailed) else { return }
        if state == drString(kDRStatusStateFailed) {
            failure = DiscBurner.failureMessage(from: status) ?? "The burn failed."
        }
        timer?.cancel()
        timer = nil
        continuation.finish()
        finished.leave()
    }

    private var lastState: String?

    /// Stopping a real burn partway usually ruins a write-once disc.
    public func cancel() {
        queue.async { [self] in
            cancelled = true
            burn.abort()
        }
    }

    /// Resolves when the burn ends. Throws if it failed or was cancelled.
    public func wait() async throws {
        let outcome: (String?, Bool) = await withCheckedContinuation { waiter in
            finished.notify(queue: queue) { [self] in waiter.resume(returning: (failure, cancelled)) }
        }
        if outcome.1 { throw CLIFailure(message: "Cancelled.", exitCode: -1, wasCancelled: true) }
        if let message = outcome.0 { throw DiscBurnFailure(message) }
    }
}

/// Writes disc images through Apple's DiscRecording framework. Unlike `hdiutil burn`, this
/// doesn't need the image to contain a filesystem it recognizes, and it can't substitute one
/// of its own. That matters here, because a picture-only image has no filesystem at all.
public enum DiscBurner {
    public static let blockSize = 2048

    // MARK: Pure rules

    /// The reason a burn can't start, or nil if it can.
    public static func problem(media: DiscMedia?, imageBytes: UInt64) -> String? {
        guard let media else { return "There's no disc in the drive." }
        guard media.isBlank else { return "The disc in the drive isn't blank. These images need a blank disc." }
        guard imageBytes > 0, imageBytes % UInt64(blockSize) == 0 else {
            return "This file isn't a disc image: its size isn't a whole number of 2048-byte sectors."
        }
        let blocks = imageBytes / UInt64(blockSize)
        guard blocks <= UInt64(max(media.freeBlocks, 0)) else {
            return "This image needs \(blocks.formatted()) sectors, but the disc only has \(media.freeBlocks.formatted()) free."
        }
        return nil
    }

    /// Mode 1 on CD and plain data on DVD and BD: every block is 2048 bytes of user data, so
    /// the file's bytes are exactly what the drive receives. DVD and BD get no pre-gap, so
    /// the image's first sector lands on the disc's first sector, as the picture requires.
    static func trackProperties(blocks: UInt32, media: DiscMediaClass) -> [String: Any] {
        var properties: [String: Any] = [
            DRTrackLengthKey: DRMSF(frames: blocks) as Any,
            DRBlockSizeKey: NSNumber(value: blockSize),
            DRBlockTypeKey: NSNumber(value: kDRBlockTypeDVDData),
            DRDataFormKey: NSNumber(value: kDRDataFormDVDData),
            DRSessionFormatKey: NSNumber(value: kDRSessionFormatDVDData),
            DRTrackModeKey: NSNumber(value: media == .cd ? kDRTrackMode1Data : kDRTrackModeDVDData),
            DRVerificationTypeKey: DRVerificationTypeReceiveData as Any,
        ]
        if media != .cd { properties[DRPreGapLengthKey] = DRMSF(frames: 0) as Any }
        return properties
    }

    /// Disc-at-once is required, not merely suggested: if the drive can't do it, the burn
    /// should fail rather than quietly write the image a different way.
    static func burnProperties(media: DiscMediaClass, speed: Int?, verify: Bool, eject: Bool, testBurn: Bool) -> [String: Any] {
        var properties: [String: Any] = [
            DRBurnStrategyKey: [media.strategy],
            DRBurnStrategyIsRequiredKey: true,
            DRBurnAppendableKey: false,
            DRBurnTestingKey: testBurn,
            DRBurnUnderrunProtectionKey: true,
            DRBurnVerifyDiscKey: verify && !testBurn,
            DRBurnCompletionActionKey: eject ? DRBurnCompletionActionEject : DRBurnCompletionActionMount,
        ]
        if let speed {
            properties[DRBurnRequestedSpeedKey] = NSNumber(value: Float(speed) * media.oneXKilobytesPerSecond)
        }
        return properties
    }

    static func label(forState state: String) -> String? {
        let labels: [(CFString?, String)] = [
            (kDRStatusStatePreparing, "Preparing the drive…"),
            (kDRStatusStateTrackOpen, "Opening the track…"),
            (kDRStatusStateTrackWrite, "Writing…"),
            (kDRStatusStateTrackClose, "Closing the track…"),
            (kDRStatusStateSessionClose, "Closing the disc…"),
            (kDRStatusStateFinishing, "Finishing…"),
            (kDRStatusStateVerifying, "Verifying the disc against the image…"),
        ]
        return labels.first { drString($0.0) == state }?.1
    }

    static func failureMessage(from status: [AnyHashable: Any]) -> String? {
        guard let error = status[drString(kDRErrorStatusKey)] as? [AnyHashable: Any] else { return nil }
        let keys: [CFString?] = [kDRErrorStatusErrorStringKey, kDRErrorStatusErrorInfoStringKey, kDRErrorStatusAdditionalSenseStringKey]
        let parts = keys.compactMap { error[drString($0)] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Hardware

    /// DiscRecording learns about drives asynchronously, so one may need a moment to appear.
    static func findDevice(servicePath: String?, timeout: TimeInterval = 3) -> DRDevice? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let devices = (DRDevice.devices() as? [DRDevice]) ?? []
            if let servicePath, let match = devices.first(where: { $0.ioRegistryEntryPath() == servicePath }) { return match }
            if servicePath == nil || devices.count == 1, let only = devices.first { return only }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    static func media(of device: DRDevice) -> DiscMedia? {
        guard let status = device.status(),
              status[DRDeviceMediaStateKey] as? String == DRDeviceMediaStateMediaPresent,
              let info = status[DRDeviceMediaInfoKey] as? [AnyHashable: Any]
        else { return nil }
        let mediaClass: DiscMediaClass
        switch info[DRDeviceMediaClassKey] as? String {
        case DRDeviceMediaClassCD: mediaClass = .cd
        case DRDeviceMediaClassDVD: mediaClass = .dvd
        case DRDeviceMediaClassBD: mediaClass = .bd
        default: return nil
        }
        let free = (info[DRDeviceMediaBlocksFreeKey] as? NSNumber)?.int64Value ?? 0
        let blank = (info[DRDeviceMediaIsBlankKey] as? NSNumber)?.boolValue ?? false
        return DiscMedia(mediaClass: mediaClass, isBlank: blank, freeBlocks: free)
    }

    /// Everything that happens before the laser could fire. Writes nothing to the disc.
    static func prepare(imagePath: String, servicePath: String?) throws -> (device: DRDevice, media: DiscMedia, producer: ImageTrackProducer, track: DRTrack) {
        guard let device = findDevice(servicePath: servicePath) else {
            throw DiscBurnFailure("macOS can't see the burner. Check that it's connected, and refresh.")
        }
        let producer = try ImageTrackProducer(path: imagePath)
        let media = Self.media(of: device)
        if let problem = problem(media: media, imageBytes: producer.byteCount) { throw DiscBurnFailure(problem) }
        let track: DRTrack = DRTrack(producer: producer)
        track.setProperties(trackProperties(blocks: UInt32(producer.byteCount / UInt64(blockSize)), media: media!.mediaClass))
        return (device, media!, producer, track)
    }

    /// Starts the burn. With `testBurn` the laser stays off.
    public static func burn(imagePath: String, device: BurnDevice?, speed: Int?, verify: Bool, eject: Bool, testBurn: Bool) throws -> DiscBurnJob {
        let prepared = try prepare(imagePath: imagePath, servicePath: device?.servicePath)
        let burn: DRBurn = DRBurn(device: prepared.device)
        burn.setProperties(burnProperties(media: prepared.media.mediaClass, speed: speed, verify: verify, eject: eject, testBurn: testBurn))
        let job = DiscBurnJob(burn: burn, track: prepared.track, producer: prepared.producer)
        job.start()
        return job
    }
}
