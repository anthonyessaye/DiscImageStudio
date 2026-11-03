import XCTest
@testable import DiscImageStudioKit

final class CLIRunnerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Stands in for the real CLI so these tests don't depend on a .NET build.
    private func runner(script: String) throws -> CLIRunner {
        let url = directory.appendingPathComponent("fake-cli")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return CLIRunner(executableURL: url)
    }

    private func collect(_ job: CLIJob) async -> [CLIEvent] {
        var events: [CLIEvent] = []
        for await event in job.events { events.append(event) }
        return events
    }

    func testSeparatesStdoutAndStderrAndReportsExitCode() async throws {
        let job = try runner(script: "echo out; echo err >&2; exit 3").start([])
        let events = await collect(job)
        let result = await job.wait()

        XCTAssertTrue(events.contains(.stdout("out")))
        XCTAssertTrue(events.contains(.stderr("err")))
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.succeeded)
    }

    func testDeliversLastLineWithoutNewline() async throws {
        let job = try runner(script: "printf 'no newline'").start([])
        let events = await collect(job)
        XCTAssertEqual(events, [.stdout("no newline")])
    }

    func testPassesArgumentsWithSpacesIntact() async throws {
        let job = try runner(script: "for a in \"$@\"; do echo \"$a\"; done").start(["--input", "my picture.png"])
        let events = await collect(job)
        XCTAssertEqual(events, [.stdout("--input"), .stdout("my picture.png")])
    }

    func testParsesProgressLinesAndLeavesBadOnesAsText() async throws {
        let job = try runner(script: """
        echo '@@dis-progress {"moduleId":"cd","stage":"encode","message":"half","fraction":0.5}'
        echo '@@dis-progress {broken'
        """).start([])
        let events = await collect(job)

        XCTAssertEqual(events.count, 2)
        guard case .progress(let progress) = events[0] else {
            return XCTFail("Expected progress, got \(events[0])")
        }
        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertEqual(events[1], .stdout("@@dis-progress {broken"))
    }

    func testRequestsJsonProgressThroughEnvironment() async throws {
        let job = try runner(script: "echo \"$DISC_IMAGE_STUDIO_JSON_PROGRESS\"").start([])
        let events = await collect(job)
        XCTAssertEqual(events, [.stdout("1")])
    }

    func testCancelStopsTheProcessAndMarksResultCancelled() async throws {
        let job = try runner(script: "echo started; sleep 30").start([])
        var iterator = job.events.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .stdout("started"))

        let began = Date()
        job.cancel()
        let result = await job.wait()

        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(began), 15)
    }

    func testThrowsWhenExecutableIsMissing() {
        let missing = CLIRunner(executableURL: directory.appendingPathComponent("nope"))
        XCTAssertThrowsError(try missing.start([]))
    }
}
