import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ComposerError: LocalizedError {
    case unreadableImage(String)
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let path): "Couldn't read the image at \(path)."
        case .renderFailed: "Couldn't render the disc design."
        }
    }
}

/// One layer flattened for rendering. `baseWidthMm` and `baseHeightMm` are its size at scale 1.
public struct ComposerLayer: @unchecked Sendable {
    public var image: CGImage
    public var baseWidthMm: Double
    public var baseHeightMm: Double
    public var translateXMm: Double
    public var translateYMm: Double
    public var rotationDeg: Double
    public var scale: Double

    public init(image: CGImage, baseWidthMm: Double, baseHeightMm: Double, translateXMm: Double, translateYMm: Double, rotationDeg: Double, scale: Double) {
        self.image = image
        self.baseWidthMm = baseWidthMm
        self.baseHeightMm = baseHeightMm
        self.translateXMm = translateXMm
        self.translateYMm = translateYMm
        self.rotationDeg = rotationDeg
        self.scale = scale
    }
}

/// Renders the layer stack into the square picture the generators consume: its centre is the
/// disc centre and its side spans twice the canvas outer radius. Same contract as the Windows
/// app's `DesignComposer`.
public enum DesignComposer {
    /// Larger images are downscaled once on load, which stays invisible at the 8192 px export.
    public static let maxDecodeSize = 4096
    public static let previewSize = 2048
    public static let exportSize = 8192
    public static let thumbnailSize = 256

    /// CD always uses a fixed 57.5 mm picture radius, and DVD and BD use the generated one.
    public static func canvasOuterRadius(family: DiscFamily, geometry: ProjectGeometry) -> Double {
        family == .cd ? 57.5 : geometry.outerRadiusMm
    }

    /// Size at scale 1: the image's larger side spans the content ring's diameter.
    public static func baseSize(imageWidth: Int, imageHeight: Int, contentOuterRadiusMm: Double) -> (width: Double, height: Double) {
        let diameter = 2 * contentOuterRadiusMm
        let w = Double(imageWidth), h = Double(imageHeight)
        return w >= h ? (diameter, diameter * h / w) : (diameter * w / h, diameter)
    }

    /// Decodes a picture, applying its orientation tag and the size cap.
    public static func loadImage(path: String, maxSize: Int = maxDecodeSize) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `layers` runs topmost-first, like the layer panel, so painting goes in reverse.
    public static func render(layers: [ComposerLayer], canvasOuterRadiusMm: Double, outputSize: Int) throws -> CGImage {
        guard canvasOuterRadiusMm > 0, outputSize > 0,
              let context = CGContext(
                data: nil, width: outputSize, height: outputSize, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ComposerError.renderFailed }

        context.interpolationQuality = .high
        let size = CGFloat(outputSize)
        let pixelsPerMm = Double(outputSize) / (2 * canvasOuterRadiusMm)
        let center = Double(outputSize) / 2

        // Work in y-down coordinates, as project files do: +y is down and rotation is clockwise.
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: 1, y: -1)

        for layer in layers.reversed() {
            let width = layer.baseWidthMm * layer.scale * pixelsPerMm
            let height = layer.baseHeightMm * layer.scale * pixelsPerMm
            guard width > 0, height > 0 else { continue }
            context.saveGState()
            context.translateBy(x: center + layer.translateXMm * pixelsPerMm, y: center + layer.translateYMm * pixelsPerMm)
            context.rotate(by: layer.rotationDeg * .pi / 180)
            // CGContext.draw puts an image's first row at the top of its rect in y-up space.
            // Flip locally so it lands the right way up in this y-down space.
            context.scaleBy(x: 1, y: -1)
            context.draw(layer.image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            context.restoreGState()
        }

        guard let image = context.makeImage() else { throw ComposerError.renderFailed }
        return image
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ComposerError.renderFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ComposerError.renderFailed }
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ComposerError.renderFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ComposerError.renderFailed }
        return data as Data
    }
}
