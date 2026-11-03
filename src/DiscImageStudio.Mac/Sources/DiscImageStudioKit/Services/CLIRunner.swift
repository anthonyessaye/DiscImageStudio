import Foundation

/// Structured progress the CLI prints when `DISC_IMAGE_STUDIO_JSON_PROGRESS=1` is set.
public struct CLIProgress: Codable, Equatable, Sendable {
    public var moduleId: String
    public var stage: String
    public var message: String
    public var fraction: Double?
    public var completedUnits: Int64?
    public var totalUnits: Int64?
}

public enum CLIEvent: Equatable, Sendable {
    case stdout(String)
    case stderr(String)
    case progress(CLIProgress)
}

public struct CLIResult: Equatable, Sendable {
    public var exitCode: Int32
    public var wasCancelled: Bool

    public var succeeded: Bool { exitCode == 0 && !wasCancelled }
}

/// Runs the bundled `disc-image-studio` executable and streams its output line by line.
public struct CLIRunner: Sendable {
    public static let progressPrefix = "@@dis-progress "
    public static let progressEnvironmentKey = "DISC_IMAGE_STUDIO_JSON_PROGRESS"

    public var executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// Finds the CLI: an explicit override first (for development), then the app bundle.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> CLIRunner? {
        var candidates: [URL] = []
        if let override = environment["DISC_IMAGE_STUDIO_CLI"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = bundle.resourceURL {
            candidates.append(resources.appendingPathComponent("cli/disc-image-studio"))
        }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            .map(CLIRunner.init(executableURL:))
    }

    /// Starts the process. Throws only if it could not be launched.
    public func start(_ arguments: [String]) throws -> CLIJob {
        try CLIJob(executableURL: executableURL, arguments: arguments)
    }
}

/// One running CLI process. Read `events` for output, and `wait()` for the result.
public final class CLIJob: @unchecked Sendable {
    public let events: AsyncStream<CLIEvent>

    private let process = Process()
    private let continuation: AsyncStream<CLIEvent>.Continuation
    private let queue = DispatchQueue(label: "DiscImageStudio.CLIJob")
    private let finished = DispatchGroup()
    private var cancelled = false
    private var openPipes: [Pipe] = []

    /// How long a cancelled job gets to stop cleanly on SIGINT before it is terminated.
    private static let cancelGracePeriod: DispatchTimeInterval = .seconds(5)

    /// How long after exit to wait for the last output. A process's children can inherit the
    /// pipes and hold them open, and they must not keep a finished job looking alive.
    private static let drainPeriod: DispatchTimeInterval = .seconds(2)

    init(executableURL: URL, arguments: [String]) throws {
        var streamContinuation: AsyncStream<CLIEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { streamContinuation = $0 }
        continuation = streamContinuation

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment[CLIRunner.progressEnvironmentKey] = "1"
        process.environment = environment

        finished.enter()
        process.terminationHandler = { [self] _ in
            queue.asyncAfter(deadline: .now() + CLIJob.drainPeriod) { [self] in
                for pipe in openPipes { closeOutput(of: pipe, buffer: nil, isError: false) }
            }
            finished.leave()
        }
        attach(outPipe, isError: false)
        attach(errPipe, isError: true)

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }

        finished.notify(queue: queue) { [continuation] in continuation.finish() }
    }

    /// Asks the process to stop: SIGINT (which the CLI treats as Ctrl-C), then SIGTERM if it
    /// is still running after the grace period.
    public func cancel() {
        queue.async { [self] in
            guard process.isRunning, !cancelled else { return }
            cancelled = true
            process.interrupt()
            queue.asyncAfter(deadline: .now() + CLIJob.cancelGracePeriod) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Resolves after the process has exited and all of its output has been delivered.
    public func wait() async -> CLIResult {
        await withCheckedContinuation { waiter in
            finished.notify(queue: queue) { [self] in
                waiter.resume(returning: CLIResult(
                    exitCode: process.terminationStatus,
                    wasCancelled: cancelled
                ))
            }
        }
    }

    /// Splits on newline bytes, not decoded text, so a multi-byte character arriving across
    /// two reads is never broken. Any unterminated last line is delivered at end of file.
    private func attach(_ pipe: Pipe, isError: Bool) {
        finished.enter()
        openPipes.append(pipe)
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            queue.sync {
                guard openPipes.contains(where: { $0 === pipe }) else { return }
                if chunk.isEmpty {
                    closeOutput(of: pipe, buffer: buffer, isError: isError)
                    buffer.removeAll()
                    return
                }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    emit(buffer[buffer.startIndex..<newline], isError: isError)
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
        }
    }

    /// Stops reading one pipe, exactly once. Runs on `queue`.
    private func closeOutput(of pipe: Pipe, buffer: Data?, isError: Bool) {
        guard let index = openPipes.firstIndex(where: { $0 === pipe }) else { return }
        openPipes.remove(at: index)
        pipe.fileHandleForReading.readabilityHandler = nil
        if let buffer, !buffer.isEmpty { emit(buffer, isError: isError) }
        finished.leave()
    }

    private func emit(_ bytes: Data, isError: Bool) {
        var line = String(decoding: bytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        if !isError, line.hasPrefix(CLIRunner.progressPrefix),
           let progress = try? JSONDecoder().decode(
               CLIProgress.self,
               from: Data(line.dropFirst(CLIRunner.progressPrefix.count).utf8)
           ) {
            continuation.yield(.progress(progress))
            return
        }
        continuation.yield(isError ? .stderr(line) : .stdout(line))
    }
}
