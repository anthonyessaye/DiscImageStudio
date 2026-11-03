import Foundation

public struct BurnDevice: Identifiable, Equatable, Sendable {
    public var index: Int
    public var vendor: String
    public var product: String

    public var id: Int { index }
    public var name: String { "\(vendor) \(product)".trimmingCharacters(in: .whitespaces) }
}

public enum BurnEvent: Equatable, Sendable {
    case progress(Double?)
    case message(String)
}

/// Burns through macOS's own tools. The Windows app streams through IMAPI2 and has a
/// disc-at-once path that keeps every sector, and neither exists here, so these results are
/// not known to be equivalent. The Burn page says so.
public enum BurnService {
    /// Parses `drutil list`: a header row, then rows that start with a device number.
    public static func parseDeviceList(_ output: String) -> [BurnDevice] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 3, let index = Int(parts[0]) else { return nil }
            // Columns after the product name are Rev, Bus and SupportLevel.
            let product = parts.count > 5 ? parts[2..<(parts.count - 3)].joined(separator: " ") : parts[2]
            return BurnDevice(index: index, vendor: parts[1], product: product)
        }
    }

    public static func listDevices() async -> [BurnDevice] {
        let runner = CLIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/drutil"))
        guard let output = try? await runner.capture(["list"]) else { return [] }
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

    /// Every option that could alter the image is turned off: the picture only exists if the
    /// exact bytes reach the disc, and by default hdiutil may add a partition map, optimize
    /// the image, or synthesize a new filesystem.
    public static func burnArguments(imagePath: String, device: BurnDevice?, speed: Int?, verify: Bool, eject: Bool, testBurn: Bool = false) -> [String] {
        var arguments = [
            "burn", imagePath, "-puppetstrings",
            "-noaddpmap", "-nooptimizeimage", "-noskipfinalfree", "-nosynthesize",
        ]
        if let device { arguments += ["-device", String(device.index)] }
        if let speed { arguments += ["-speed", String(speed)] }
        if testBurn { arguments.append("-testburn") }
        if !verify { arguments.append("-noverifyburn") }
        if !eject { arguments.append("-noeject") }
        return arguments
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

    public static func burn(imagePath: String, device: BurnDevice?, speed: Int?, verify: Bool, eject: Bool, testBurn: Bool) throws -> CLIJob {
        try CLIRunner(executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"))
            .start(burnArguments(imagePath: imagePath, device: device, speed: speed, verify: verify, eject: eject, testBurn: testBurn))
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
