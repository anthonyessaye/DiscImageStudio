import Foundation

/// A disc's physical parameters plus the settings a generation job needs, gathered from a
/// project so the argument builders below stay pure functions.
public struct DiscJobSettings: Equatable, Sendable {
    public var family: DiscFamily
    public var geometry: ProjectGeometry
    public var tone: ToneProfile
    public var invertMapping: Bool
    public var outputs: ProjectOutputs

    public init(family: DiscFamily, geometry: ProjectGeometry, tone: ToneProfile, invertMapping: Bool, outputs: ProjectOutputs) {
        self.family = family
        self.geometry = geometry
        self.tone = tone
        self.invertMapping = invertMapping
        self.outputs = outputs
    }

    public init(project: ProjectDocument) {
        self.init(
            family: project.discFamily,
            geometry: project.geometry,
            tone: project.tone ?? ToneProfile(ditherStrength: 0, levels: 2, brightness: 0),
            invertMapping: project.bluRay?.invertMapping ?? false,
            outputs: project.outputs
        )
    }

    public var dataDirectory: String { outputs.dataDirectory.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var hasFiles: Bool { !dataDirectory.isEmpty }
    public var filePosition: String { outputs.filesAtOuterRing ? "outer" : "inner" }

    /// Each family's default label, used when the field is left blank.
    public var volumeLabel: String {
        let trimmed = outputs.volumeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch family {
        case .cd: return "CD_IMAGE"
        case .dvd: return "DISC_IMAGE"
        case .bd: return "BD_IMAGE"
        }
    }
}

/// Measured-disc values for previews, which start out equal to the generation geometry.
public struct MeasuredGeometry: Equatable, Sendable {
    public var innerRadiusMm: Double
    public var outerRadiusMm: Double
    public var pitchLinear: Double
    public var pitchQuadratic: Double
    public var pitchCubic: Double

    public init(innerRadiusMm: Double, outerRadiusMm: Double, pitchLinear: Double = 0, pitchQuadratic: Double = 0, pitchCubic: Double = 0) {
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.pitchLinear = pitchLinear
        self.pitchQuadratic = pitchQuadratic
        self.pitchCubic = pitchCubic
    }

    public init(geometry: ProjectGeometry) {
        self.init(
            innerRadiusMm: geometry.innerRadiusMm,
            outerRadiusMm: geometry.outerRadiusMm,
            pitchLinear: geometry.pitchLinear,
            pitchQuadratic: geometry.pitchQuadratic,
            pitchCubic: geometry.pitchCubic
        )
    }
}

/// Builds CLI arguments, matching what the Windows app passes for the same settings.
public enum CommandBuilder {
    /// Doubles in their shortest round-trip form, so geometry reaches the engine unchanged.
    public static func number(_ value: Double) -> String { "\(value)" }

    private static func toneArguments(_ tone: ToneProfile, levels: Int? = nil) -> [String] {
        [
            "--tone-dither", number(tone.ditherStrength),
            "--tone-levels", String(levels ?? tone.levels),
            "--tone-brightness", number(tone.brightness),
            "--tone-gamma", String(tone.srgbLinearization),
        ]
    }

    private static func dvdPitch(_ g: ProjectGeometry) -> [String] {
        [
            "--pitch-linear", number(g.pitchLinear),
            "--pitch-quadratic", number(g.pitchQuadratic),
            "--pitch-cubic", number(g.pitchCubic),
        ]
    }

    // MARK: Generation

    public static func generate(_ s: DiscJobSettings, compositePath: String) -> [String] {
        let g = s.geometry
        let output = s.outputs.outputPath
        switch s.family {
        case .cd:
            var arguments = [
                "cd-generate", "--input", compositePath, "--output", output,
                "--r0", number(g.innerRadiusMm), "--r1", number(g.outerRadiusMm), "--sectors", String(g.sectors),
            ] + toneArguments(s.tone)
            if s.hasFiles {
                arguments += ["--data-dir", s.dataDirectory, "--volume-label", s.volumeLabel, "--file-position", s.filePosition]
            } else {
                arguments += ["--interleave", String(s.outputs.interleave), "--cue", String(s.outputs.writeCue)]
            }
            return arguments
        case .dvd:
            var arguments = [
                "solve", "--image", compositePath, "--iso-output", output,
                "--total-sectors", String(g.sectors),
                "--inner-radius-mm", number(g.innerRadiusMm), "--outer-radius-mm", number(g.outerRadiusMm),
            ] + dvdPitch(g) + [
                "--spiral-direction", "cw", "--image-threshold", "128", "--alpha-threshold", "1",
            ] + toneArguments(s.tone, levels: 2) + [
                "--algorithm", "dispersion", "--iterations-per-block", "1", "--fast-output", "true",
                "--volume-label", s.volumeLabel,
            ]
            if s.hasFiles {
                arguments += ["--data-dir", s.dataDirectory, "--file-position", s.filePosition]
            } else {
                arguments += ["--fill-sectors", String(g.sectors)]
            }
            return arguments
        case .bd:
            var arguments = [
                "bd-generate", "--input", compositePath, "--output", output,
                "--total-sectors", String(g.sectors),
                "--r0", number(g.innerRadiusMm), "--r1", number(g.outerRadiusMm),
                "--invert", String(s.invertMapping), "--volume-label", s.volumeLabel,
            ] + toneArguments(s.tone, levels: 2)
            if s.hasFiles {
                arguments += ["--data-dir", s.dataDirectory, "--file-position", s.filePosition]
            }
            return arguments
        }
    }

    // MARK: Design projection

    /// Projects a source picture from the generation geometry onto the measured one.
    /// `drawing` is the sector range left for the picture when files take part of the disc.
    public static func projection(
        _ s: DiscJobSettings,
        measured: MeasuredGeometry,
        sourcePath: String,
        outputPath: String,
        size: Int,
        samplesPerSector: Int,
        drawing: (start: Int64, end: Int64)?
    ) -> [String] {
        let g = s.geometry
        switch s.family {
        case .cd:
            var arguments = [
                "cd-preview-warp", "--input", sourcePath, "--output", outputPath,
                "--r0", number(g.innerRadiusMm), "--r1", number(g.outerRadiusMm), "--sectors", String(g.sectors),
                "--actual-r0", number(measured.innerRadiusMm), "--actual-r1", number(measured.outerRadiusMm),
                "--size", String(size), "--samples-per-sector", String(samplesPerSector),
            ] + toneArguments(s.tone)
            if s.hasFiles {
                arguments += ["--data-dir", s.dataDirectory, "--volume-label", s.volumeLabel, "--file-position", s.filePosition]
            }
            return arguments
        case .dvd:
            let start = drawing?.start ?? 0
            let sectors = drawing.map { $0.end - $0.start } ?? g.sectors
            return [
                "calibrate", "--image", sourcePath, "--output", outputPath,
                "--total-sectors", String(g.sectors), "--lba", String(start), "--fill-sectors", String(sectors),
                "--generated-inner-radius-mm", number(g.innerRadiusMm), "--generated-outer-radius-mm", number(g.outerRadiusMm),
                "--actual-inner-radius-mm", number(measured.innerRadiusMm), "--actual-outer-radius-mm", number(measured.outerRadiusMm),
            ] + dvdPitch(g) + [
                "--actual-pitch-linear", number(measured.pitchLinear),
                "--actual-pitch-quadratic", number(measured.pitchQuadratic),
                "--actual-pitch-cubic", number(measured.pitchCubic),
                "--spiral-direction", "cw", "--image-threshold", "128", "--alpha-threshold", "1",
            ] + toneArguments(s.tone, levels: 2) + [
                "--preview-size", String(size), "--samples-per-sector", String(samplesPerSector),
            ]
        case .bd:
            var arguments = [
                "gui-bd-preview", "--mode", "calibration", "--input", sourcePath, "--output", outputPath,
                "--size", String(size), "--total-sectors", String(g.sectors),
                "--r0", number(g.innerRadiusMm), "--r1", number(g.outerRadiusMm),
                "--actual-r0", number(measured.innerRadiusMm), "--actual-r1", number(measured.outerRadiusMm),
                "--invert", String(s.invertMapping),
            ] + toneArguments(s.tone, levels: 2)
            if let drawing {
                arguments += ["--drawing-start", String(drawing.start), "--drawing-end", String(drawing.end)]
            }
            return arguments
        }
    }

    // MARK: Read-back of a finished file

    public static func readback(
        _ s: DiscJobSettings,
        measured: MeasuredGeometry,
        artifactPath: String,
        outputPath: String,
        size: Int,
        samplesPerSector: Int
    ) -> [String] {
        let g = s.geometry
        switch s.family {
        case .cd:
            // A data image has 2048 payload bytes per sector, and audio has 2352.
            let isData = artifactPath.lowercased().hasSuffix(".iso")
            let bytesPerSector = isData ? 2048 : 2352
            var arguments = [
                "cd-preview-track", "--track", artifactPath, "--output", outputPath,
                "--r0", number(measured.innerRadiusMm), "--r1", number(measured.outerRadiusMm), "--sectors", String(g.sectors),
                "--size", String(size), "--byte-step", String(bytesPerSector / max(samplesPerSector, 1)),
            ]
            if !isData { arguments += ["--deinterleave", String(s.outputs.interleave)] }
            return arguments
        case .dvd:
            return [
                "simulate", "--iso", artifactPath, "--output", outputPath, "--total-sectors", String(g.sectors),
                "--inner-radius-mm", number(measured.innerRadiusMm), "--outer-radius-mm", number(measured.outerRadiusMm),
                "--pitch-linear", number(measured.pitchLinear),
                "--pitch-quadratic", number(measured.pitchQuadratic),
                "--pitch-cubic", number(measured.pitchCubic),
                "--spiral-direction", "cw", "--preview-size", String(size), "--samples-per-sector", String(samplesPerSector),
            ]
        case .bd:
            return [
                "gui-bd-preview", "--mode", "readback", "--input", artifactPath, "--output", outputPath,
                "--size", String(size), "--total-sectors", String(g.sectors),
                "--actual-r0", number(measured.innerRadiusMm), "--actual-r1", number(measured.outerRadiusMm),
            ]
        }
    }

    // MARK: Design page tone preview

    public static func tonePreview(_ s: DiscJobSettings, sourcePath: String, outputPath: String) -> [String] {
        let g = s.geometry
        switch s.family {
        case .cd:
            return projection(s, measured: MeasuredGeometry(geometry: g), sourcePath: sourcePath, outputPath: outputPath,
                              size: 420, samplesPerSector: 32, drawing: nil)
        case .dvd:
            return [
                "gui-dvd-tone-preview", "--input", sourcePath, "--output", outputPath,
                "--size", "420", "--samples-per-sector", "8", "--total-sectors", String(g.sectors),
                "--r0", number(g.innerRadiusMm), "--r1", number(g.outerRadiusMm),
            ] + dvdPitch(g) + toneArguments(s.tone, levels: 2)
        case .bd:
            return [
                "gui-bd-preview", "--mode", "projection", "--input", sourcePath, "--output", outputPath,
                "--size", "512", "--total-sectors", String(g.sectors),
                "--r0", number(g.innerRadiusMm), "--r1", number(g.outerRadiusMm),
                "--invert", String(s.invertMapping),
            ] + toneArguments(s.tone, levels: 2)
        }
    }

    // MARK: Helper arguments shared by the geometry-taking helpers

    /// Generation geometry in the form the `gui-` helpers read.
    public static func helperGeometry(_ family: DiscFamily, _ g: ProjectGeometry) -> [String] {
        let sectorsKey = family == .cd ? "--sectors" : "--total-sectors"
        return ["--family", family.rawValue, sectorsKey, String(g.sectors),
                "--r0", number(g.innerRadiusMm), "--r1", number(g.outerRadiusMm)]
            + (family == .dvd ? dvdPitch(g) : [])
    }

    public static func overlay(_ s: DiscJobSettings, measured: MeasuredGeometry, path: String, drawing: (start: Int64, end: Int64)) -> [String] {
        let sectorsKey = s.family == .cd ? "--sectors" : "--total-sectors"
        return [
            "gui-preview-overlay", "--family", s.family.rawValue, "--input", path,
            "--drawing-start", String(drawing.start), "--drawing-end", String(drawing.end),
            sectorsKey, String(s.geometry.sectors),
            "--actual-r0", number(measured.innerRadiusMm), "--actual-r1", number(measured.outerRadiusMm),
            "--actual-pitch-linear", number(measured.pitchLinear),
            "--actual-pitch-quadratic", number(measured.pitchQuadratic),
            "--actual-pitch-cubic", number(measured.pitchCubic),
        ]
    }

    public static func drawingPlan(_ s: DiscJobSettings) -> [String] {
        ["gui-drawing-plan"] + helperGeometry(s.family, s.geometry) + [
            "--data-dir", s.dataDirectory, "--file-position", s.filePosition, "--volume-label", s.volumeLabel,
        ]
    }
}
