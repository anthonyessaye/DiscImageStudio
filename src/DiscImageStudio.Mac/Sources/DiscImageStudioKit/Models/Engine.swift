import Foundation

// MARK: Presets (gui-presets)

public struct DiscPresetCatalog: Decodable, Sendable {
    public var cdPresets: [RawPreset]
    public var dvdPresets: [RawPreset]
    public var bluRayPresets: [RawPreset]?

    /// CD files say `sectors`, and DVD and BD files say `totalSectors`.
    public struct RawPreset: Decodable, Sendable {
        public var id: String
        public var displayName: String
        public var description: String
        public var sectors: Int64?
        public var totalSectors: Int64?
        public var innerRadiusMm: Double
        public var outerRadiusMm: Double
        public var pitchLinear: Double?
        public var pitchQuadratic: Double?
        public var pitchCubic: Double?
        public var invertMapping: Bool?
    }

    public func presets(for family: DiscFamily) -> [DiscPreset] {
        let raw: [RawPreset]
        switch family {
        case .cd: raw = cdPresets
        case .dvd: raw = dvdPresets
        case .bd: raw = bluRayPresets ?? []
        }
        return raw.map { preset in
            DiscPreset(
                id: preset.id,
                family: family,
                displayName: preset.displayName,
                description: preset.description,
                geometry: ProjectGeometry(
                    innerRadiusMm: preset.innerRadiusMm,
                    outerRadiusMm: preset.outerRadiusMm,
                    sectors: preset.sectors ?? preset.totalSectors ?? 0,
                    pitchLinear: preset.pitchLinear ?? 0,
                    pitchQuadratic: preset.pitchQuadratic ?? 0,
                    pitchCubic: preset.pitchCubic ?? 0
                ),
                invertMapping: preset.invertMapping ?? false
            )
        }
    }
}

public struct DiscPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var family: DiscFamily
    public var displayName: String
    public var description: String
    public var geometry: ProjectGeometry
    public var invertMapping: Bool

    public static func == (a: DiscPreset, b: DiscPreset) -> Bool { a.id == b.id && a.family == b.family }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(family)
    }
}

extension DiscPresetCatalog.RawPreset {
    /// Lets tests build a preset without a JSON document.
    public init(id: String, name: String, sectors: Int64, inner: Double, outer: Double) {
        self.id = id
        displayName = name
        description = name
        self.sectors = sectors
        totalSectors = nil
        innerRadiusMm = inner
        outerRadiusMm = outer
    }
}

// MARK: Helper responses

public struct DrawingPlan: Decodable, Sendable {
    public var start: Int64
    public var end: Int64
}

public struct BluRayPreviewResult: Decodable, Sendable {
    public var output: String
    public var drawingStart: Int64
    public var drawingEnd: Int64
    public var hasSidecar: Bool
    public var hasFileRegion: Bool
}

/// A generated file's sidecar, read through gui-artifact-info.
public struct ArtifactInfo: Decodable, Sendable {
    public var hasSidecar: Bool
    public var innerRadiusMm: Double?
    public var outerRadiusMm: Double?
    public var sectors: Int64?
    public var pitchLinear: Double?
    public var pitchQuadratic: Double?
    public var pitchCubic: Double?
    public var interleaved: Bool?
    public var drawingStart: Int64?
    public var drawingEnd: Int64?
    public var hasFileRegion: Bool
}

// MARK: Calibration (gui-calibration-*)

public struct CalibrationPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CalibrationParameters: Codable, Equatable, Sendable {
    public var kind: String
    public var innerRadiusMm: Double
    public var outerRadiusMm: Double
    public var sectors: Int64
    public var linearDensity: Double
    public var pitchLinear: Double
    public var pitchQuadratic: Double
    public var pitchCubic: Double
    public var bluRayInvertMapping: Bool

    public var family: DiscFamily {
        switch kind {
        case "Dvd": .dvd
        case "BluRay": .bd
        default: .cd
        }
    }
}

public struct CalibrationCrossTrace: Codable, Equatable, Sendable {
    public var armIndex: Int
    public var points: [CalibrationPoint]

    public init(armIndex: Int = 0, points: [CalibrationPoint]) {
        self.armIndex = armIndex
        self.points = points
    }
}

public struct CalibrationPhoto: Codable, Equatable, Sendable {
    public var imagePngBase64: String
    public var outerBoundary: [CalibrationPoint]
    public var holeBoundary: [CalibrationPoint]
    public var physicalOuterRadiusMm: Double
    public var rectificationConfirmed: Bool
    public var traces: [CalibrationCrossTrace]

    public init(imagePngBase64: String, outerBoundary: [CalibrationPoint], holeBoundary: [CalibrationPoint],
                physicalOuterRadiusMm: Double, rectificationConfirmed: Bool, traces: [CalibrationCrossTrace]) {
        self.imagePngBase64 = imagePngBase64
        self.outerBoundary = outerBoundary
        self.holeBoundary = holeBoundary
        self.physicalOuterRadiusMm = physicalOuterRadiusMm
        self.rectificationConfirmed = rectificationConfirmed
        self.traces = traces
    }
}

public struct CalibrationFitOptions: Codable, Equatable, Sendable {
    public var radiusRangeMm: Double
    public var fitDvdPitch: Bool
    public var autoRange: Bool?
}

public struct CalibrationSessionInfo: Decodable, Sendable {
    public var sessionPath: String
    public var id: String
    public var parameters: CalibrationParameters
    public var canvasOuterRadiusMm: Double
    public var cdInterleave: Bool
    public var fitOptions: CalibrationFitOptions?
    public var photo: CalibrationPhoto?
}

public struct CalibrationSaveRequest: Encodable, Sendable {
    public var photo: CalibrationPhoto?
    public var radiusRangeMm: Double
    public var autoRange: Bool
    public var fitDvdPitch: Bool

    public init(photo: CalibrationPhoto?, radiusRangeMm: Double, autoRange: Bool, fitDvdPitch: Bool) {
        self.photo = photo
        self.radiusRangeMm = radiusRangeMm
        self.autoRange = autoRange
        self.fitDvdPitch = fitDvdPitch
    }
}

public struct CalibrationCandidate: Decodable, Identifiable, Sendable {
    public var parameters: CalibrationParameters
    public var rotationRadians: Double
    public var rmsErrorMm: Double
    public var maxErrorMm: Double
    public var outlierCount: Int
    public var accepted: Bool
    public var outline: [CalibrationPoint]
    public var outlineError: String?
    public var outlierPointIndices: [Int]

    public var id: String { "\(parameters.innerRadiusMm)-\(parameters.outerRadiusMm)-\(rotationRadians)" }
}

public struct CalibrationFitOutcome: Decodable, Sendable {
    public var succeeded: Bool
    public var boundaryLimited: Bool
    public var rangeMm: Double
    public var rangeExpanded: Bool
    public var warnings: [String]
    public var candidates: [CalibrationCandidate]
}

public struct PhotoRectifyRequest: Encodable, Sendable {
    public var outer: [CalibrationPoint]
    public var hole: [CalibrationPoint]
    public var physicalOuterRadiusMm: Double

    public init(outer: [CalibrationPoint], hole: [CalibrationPoint], physicalOuterRadiusMm: Double) {
        self.outer = outer
        self.hole = hole
        self.physicalOuterRadiusMm = physicalOuterRadiusMm
    }
}

public struct PhotoRectifyResult: Decodable, Sendable {
    public var succeeded: Bool
    public var message: String
    public var outerRmsPixels: Double
    public var holeRmsPixels: Double
    public var output: String?
    public var canvasRadiusMm: Double?
    public var pixelSize: Int?
}

// MARK: Running helpers

public struct CLIFailure: LocalizedError, Sendable {
    public var message: String
    public var exitCode: Int32
    public var wasCancelled: Bool

    public init(message: String, exitCode: Int32, wasCancelled: Bool) {
        self.message = message
        self.exitCode = exitCode
        self.wasCancelled = wasCancelled
    }

    public var errorDescription: String? { message }
}

extension CLIRunner {
    /// Runs a command to completion and returns its stdout. Failures throw with the CLI's
    /// `error:` line as the message.
    public func capture(_ arguments: [String], onJob: ((CLIJob) -> Void)? = nil) async throws -> String {
        let job = try start(arguments)
        onJob?(job)
        var out: [String] = []
        var err: [String] = []
        for await event in job.events {
            switch event {
            case .stdout(let line): out.append(line)
            case .stderr(let line): err.append(line)
            case .progress: break
            }
        }
        let result = await job.wait()
        guard result.succeeded else {
            let raw = err.last(where: { !$0.isEmpty }) ?? "The command failed with exit code \(result.exitCode)."
            let message = raw.hasPrefix("error: ") ? String(raw.dropFirst(7)) : raw
            throw CLIFailure(message: result.wasCancelled ? "Cancelled." : message, exitCode: result.exitCode, wasCancelled: result.wasCancelled)
        }
        return out.joined(separator: "\n")
    }

    public func json<T: Decodable>(_ type: T.Type, _ arguments: [String], onJob: ((CLIJob) -> Void)? = nil) async throws -> T {
        let output = try await capture(arguments, onJob: onJob)
        return try JSONDecoder().decode(T.self, from: Data(output.utf8))
    }
}
