import Foundation

/// Swift mirror of `DiscImageStudio.Core.ProjectDocument`, the `.discproj` file format.
/// The C# reader rejects unknown members, so the coding keys here must match its camelCase
/// names exactly. Timestamps stay strings because .NET writes seven fractional digits, which
/// a Foundation `Date` would not round-trip.
public struct ProjectDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let fileExtension = "discproj"

    public var schemaVersion: Int
    public var name: String
    public var discFamily: DiscFamily
    public var geometry: ProjectGeometry
    public var layers: [ProjectLayer]
    public var outputs: ProjectOutputs
    public var calibrationSessionPath: String?
    public var thumbnailPngBase64: String?
    public var createdUtc: String
    public var modifiedUtc: String
    public var tone: ToneProfile?
    public var bluRay: ProjectBluRaySettings?

    public init(
        schemaVersion: Int = ProjectDocument.currentSchemaVersion,
        name: String,
        discFamily: DiscFamily,
        geometry: ProjectGeometry,
        layers: [ProjectLayer] = [],
        outputs: ProjectOutputs,
        calibrationSessionPath: String? = nil,
        thumbnailPngBase64: String? = nil,
        createdUtc: String,
        modifiedUtc: String,
        tone: ToneProfile? = nil,
        bluRay: ProjectBluRaySettings? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.discFamily = discFamily
        self.geometry = geometry
        self.layers = layers
        self.outputs = outputs
        self.calibrationSessionPath = calibrationSessionPath
        self.thumbnailPngBase64 = thumbnailPngBase64
        self.createdUtc = createdUtc
        self.modifiedUtc = modifiedUtc
        self.tone = tone
        self.bluRay = bluRay
    }

    public static func load(from url: URL) throws -> ProjectDocument {
        try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
    }

    /// Writes atomically so a crash mid-save can't leave a half-written project behind.
    /// Saving always upgrades the file to the current schema, as the C# store does.
    public func save(to url: URL) throws {
        var clean = self
        clean.schemaVersion = ProjectDocument.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(clean).write(to: url, options: .atomic)
    }
}

public enum DiscFamily: String, Codable, CaseIterable, Sendable {
    case cd
    case dvd
    case bd

    public var label: String {
        switch self {
        case .cd: "CD"
        case .dvd: "DVD"
        case .bd: "BD"
        }
    }

    /// The C# store accepts any casing for this field when validating.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let family = DiscFamily(rawValue: raw.lowercased()) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown disc family '\(raw)'."
            ))
        }
        self = family
    }
}

public struct ProjectGeometry: Codable, Equatable, Sendable {
    public var innerRadiusMm: Double
    public var outerRadiusMm: Double
    public var sectors: Int64
    public var pitchLinear: Double
    public var pitchQuadratic: Double
    public var pitchCubic: Double

    public init(
        innerRadiusMm: Double,
        outerRadiusMm: Double,
        sectors: Int64,
        pitchLinear: Double = 0,
        pitchQuadratic: Double = 0,
        pitchCubic: Double = 0
    ) {
        self.innerRadiusMm = innerRadiusMm
        self.outerRadiusMm = outerRadiusMm
        self.sectors = sectors
        self.pitchLinear = pitchLinear
        self.pitchQuadratic = pitchQuadratic
        self.pitchCubic = pitchCubic
    }

    // The pitch terms have defaults in C#, so files may omit them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        innerRadiusMm = try c.decode(Double.self, forKey: .innerRadiusMm)
        outerRadiusMm = try c.decode(Double.self, forKey: .outerRadiusMm)
        sectors = try c.decode(Int64.self, forKey: .sectors)
        pitchLinear = try c.decodeIfPresent(Double.self, forKey: .pitchLinear) ?? 0
        pitchQuadratic = try c.decodeIfPresent(Double.self, forKey: .pitchQuadratic) ?? 0
        pitchCubic = try c.decodeIfPresent(Double.self, forKey: .pitchCubic) ?? 0
    }
}

/// One image placed relative to the disc centre: translation in mm (+x right, +y down),
/// rotation in degrees clockwise, scale relative to the image's initially fitted size.
public struct ProjectLayer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var imagePath: String
    public var visible: Bool
    public var translateXMm: Double
    public var translateYMm: Double
    public var rotationDeg: Double
    public var scale: Double

    public init(
        id: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
        name: String,
        imagePath: String,
        visible: Bool = true,
        translateXMm: Double = 0,
        translateYMm: Double = 0,
        rotationDeg: Double = 0,
        scale: Double = 1
    ) {
        self.id = id
        self.name = name
        self.imagePath = imagePath
        self.visible = visible
        self.translateXMm = translateXMm
        self.translateYMm = translateYMm
        self.rotationDeg = rotationDeg
        self.scale = scale
    }
}

public struct ProjectOutputs: Codable, Equatable, Sendable {
    public var outputPath: String
    public var writeCue: Bool
    public var dataDirectory: String
    public var volumeLabel: String
    public var interleave: Bool
    public var filesAtOuterRing: Bool

    public init(
        outputPath: String = "",
        writeCue: Bool = true,
        dataDirectory: String = "",
        volumeLabel: String = "",
        interleave: Bool = true,
        filesAtOuterRing: Bool = false
    ) {
        self.outputPath = outputPath
        self.writeCue = writeCue
        self.dataDirectory = dataDirectory
        self.volumeLabel = volumeLabel
        self.interleave = interleave
        self.filesAtOuterRing = filesAtOuterRing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputPath = try c.decode(String.self, forKey: .outputPath)
        writeCue = try c.decode(Bool.self, forKey: .writeCue)
        dataDirectory = try c.decode(String.self, forKey: .dataDirectory)
        volumeLabel = try c.decode(String.self, forKey: .volumeLabel)
        interleave = try c.decode(Bool.self, forKey: .interleave)
        filesAtOuterRing = try c.decodeIfPresent(Bool.self, forKey: .filesAtOuterRing) ?? false
    }
}

public struct ToneProfile: Codable, Equatable, Sendable {
    public var ditherStrength: Double
    public var levels: Int
    public var brightness: Double
    public var srgbLinearization: Bool

    /// The starting point for new projects, matching `ToneProfile.Photo` in C#.
    public static let photo = ToneProfile(ditherStrength: 0.75, levels: 2, brightness: 0)

    public init(ditherStrength: Double, levels: Int, brightness: Double, srgbLinearization: Bool = false) {
        self.ditherStrength = ditherStrength
        self.levels = levels
        self.brightness = brightness
        self.srgbLinearization = srgbLinearization
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ditherStrength = try c.decode(Double.self, forKey: .ditherStrength)
        levels = try c.decode(Int.self, forKey: .levels)
        brightness = try c.decode(Double.self, forKey: .brightness)
        srgbLinearization = try c.decodeIfPresent(Bool.self, forKey: .srgbLinearization) ?? false
    }
}

public struct ProjectBluRaySettings: Codable, Equatable, Sendable {
    public var invertMapping: Bool

    public init(invertMapping: Bool = false) {
        self.invertMapping = invertMapping
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        invertMapping = try c.decodeIfPresent(Bool.self, forKey: .invertMapping) ?? false
    }
}
