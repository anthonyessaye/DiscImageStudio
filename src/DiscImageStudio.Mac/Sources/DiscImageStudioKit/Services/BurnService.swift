import Foundation

public struct BurnDevice: Identifiable, Equatable, Sendable {
    public var index: Int
    public var name: String
    /// The drive's IOService path, which is how `DiscBurner` finds it again.
    public var servicePath: String

    public var id: Int { index }

    public init(index: Int, name: String, servicePath: String) {
        self.index = index
        self.name = name
        self.servicePath = servicePath
    }
}

public enum BurnEvent: Equatable, Sendable {
    case progress(Double?)
    case message(String)
}

/// Finds burners, and writes CD audio through drutil. Disc images go through `DiscBurner`.
/// The Windows app uses IMAPI2 instead, so results are not known to be equivalent, and the
/// Burn page says so.
public enum BurnService {
    /// Parses `hdiutil burn -list`: each drive is a name line, then an indented IOService path.
    public static func parseDeviceList(_ output: String) -> [BurnDevice] {
        var devices: [BurnDevice] = []
        var pendingName: String?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("IOService:") {
                guard let name = pendingName else { continue }
                devices.append(BurnDevice(index: devices.count + 1, name: name, servicePath: trimmed))
                pendingName = nil
            } else if !trimmed.isEmpty {
                // "TEAC DV-W28S-VT via USB (DRDeviceSupportLevelUnsupported)"
                pendingName = trimmed.components(separatedBy: " via ").first ?? trimmed
            }
        }
        return devices
    }

    public static func listDevices() async -> [BurnDevice] {
        let runner = CLIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"))
        guard let output = try? await runner.capture(["burn", "-list"]) else { return [] }
        return parseDeviceList(output)
    }

    /// `hdiutil -puppetstrings` prints `PERCENT:<n>`, where -1 means indeterminate.
    public static func parseBurnLine(_ line: String) -> BurnEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("PERCENT:") {
            guard let value = Double(trimmed.dropFirst("PERCENT:".count)) else { return nil }
            return .progress(value < 0 ? nil : min(value, 100) / 100)
        }
        for prefix in ["MESSAGE:", "ERROR:"] where trimmed.hasPrefix(prefix) {
            return .message(String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        return .message(trimmed)
    }

    /// A CD audio track goes through drutil, which reads the WAV header and so can't get the
    /// byte order wrong. It takes a folder, so the track is linked into a temporary one.
    public static func audioBurnArguments(folder: String, speed: Int?, testBurn: Bool) -> [String] {
        var arguments = ["burn", "-audio"]
        if let speed { arguments += ["-speed", String(speed)] }
        if testBurn { arguments.append("-test") }
        arguments.append(folder)
        return arguments
    }

    public static func burnAudio(wavPath: String, speed: Int?, testBurn: Bool) throws -> CLIJob {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiscImageStudio-burn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: wavPath)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(source.lastPathComponent), withDestinationURL: source)
        return try CLIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/drutil"))
            .start(audioBurnArguments(folder: folder.path, speed: speed, testBurn: testBurn))
    }
}
