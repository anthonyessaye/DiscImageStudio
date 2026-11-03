import Foundation

/// The engine's own messages (validation errors, fit warnings) are in Chinese. This reads the
/// Windows app's catalog files, plus the Mac app's own Catalogs/engine-messages.json for the
/// engine messages those files don't cover.
public final class EngineText: @unchecked Sendable {
    private var exact: [String: String] = [:]
    private var patterns: [(regex: NSRegularExpression, english: String)] = []

    public init(catalogDirectories: [URL]) {
        for directory in catalogDirectories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
                else { continue }
                for (key, translations) in catalog {
                    guard let english = translations["en"], !english.isEmpty else { continue }
                    if let source = translations["zh-CN"], !source.isEmpty { add(source, english) }
                    add(key, english)
                }
            }
        }
    }

    /// Finds the catalogs next to the app's resources, or in a source checkout during development.
    public static func locate(bundle: Bundle = .main) -> EngineText {
        var directories: [URL] = []
        if let resources = bundle.resourceURL {
            directories.append(resources.appendingPathComponent("Catalogs"))
        }
        if let root = ProcessInfo.processInfo.environment["DISC_IMAGE_STUDIO_ROOT"] {
            let rootURL = URL(fileURLWithPath: root)
            directories.append(rootURL.appendingPathComponent("src/DiscImageStudio.App/Localization/Catalogs"))
            directories.append(rootURL.appendingPathComponent("src/DiscImageStudio.Mac/Catalogs"))
        }
        return EngineText(catalogDirectories: directories)
    }

    private func add(_ source: String, _ english: String) {
        guard source.contains("{0") else {
            exact[source] = english
            return
        }
        // "{0:N0}" holes become capture groups, and the same holes in the English text get the values.
        let escaped = NSRegularExpression.escapedPattern(for: source)
        let holes = try! NSRegularExpression(pattern: #"\\\{(\d+)(?::[^}]*)?\\\}"#)
        let pattern = holes.stringByReplacingMatches(
            in: escaped, range: NSRange(escaped.startIndex..., in: escaped), withTemplate: "(.+?)"
        )
        if let regex = try? NSRegularExpression(pattern: "^\(pattern)$", options: .dotMatchesLineSeparators) {
            patterns.append((regex, english))
        }
    }

    /// The English text, or the original when the catalog has no entry: an untranslated
    /// message is still more useful than none.
    public func translate(_ message: String) -> String {
        if let english = exact[message] { return english }
        let range = NSRange(message.startIndex..., in: message)
        for (regex, english) in patterns {
            guard let match = regex.firstMatch(in: message, range: range) else { continue }
            var result = english
            for group in 1..<match.numberOfRanges {
                guard let capture = Range(match.range(at: group), in: message) else { continue }
                let hole = try! NSRegularExpression(pattern: "\\{\(group - 1)(?::[^}]*)?\\}")
                result = hole.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: String(message[capture]))
                )
            }
            return result
        }
        return message
    }
}
