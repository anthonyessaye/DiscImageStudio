import CoreGraphics
import XCTest
@testable import DiscImageStudioKit

final class DesignComposerTests: XCTestCase {
    /// Four solid quadrants, so any flip or wrong-way rotation changes which colour lands where.
    private func quadrants() -> CGImage {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow
        // Memory order, first row first: this is the image's top row.
        let pixels: [[(UInt8, UInt8, UInt8)]] = [
            [(255, 0, 0), (0, 255, 0)],     // top-left red, top-right green
            [(0, 0, 255), (255, 255, 0)],   // bottom-left blue, bottom-right yellow
        ]
        for (y, row) in pixels.enumerated() {
            for (x, p) in row.enumerated() {
                let o = y * bytesPerRow + x * 4
                data[o] = p.0; data[o + 1] = p.1; data[o + 2] = p.2; data[o + 3] = 255
            }
        }
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var buffer = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &buffer, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Places the wanted pixel over the context's single pixel; bitmap contexts are y-up.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    private func layer(rotation: Double = 0, x: Double = 0, y: Double = 0, scale: Double = 1, image: CGImage? = nil) -> ComposerLayer {
        ComposerLayer(image: image ?? quadrants(), baseWidthMm: 100, baseHeightMm: 100,
                      translateXMm: x, translateYMm: y, rotationDeg: rotation, scale: scale)
    }

    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
    private func isGreen(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.g > 200 && p.r < 60 && p.b < 60 }
    private func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.b > 200 && p.r < 60 && p.g < 60 }
    private func isYellow(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool { p.r > 200 && p.g > 200 && p.b < 60 }

    func testKeepsImageTheRightWayUp() throws {
        let out = try DesignComposer.render(layers: [layer()], canvasOuterRadiusMm: 50, outputSize: 100)
        XCTAssertTrue(isRed(pixel(out, 25, 25)), "top-left")
        XCTAssertTrue(isGreen(pixel(out, 75, 25)), "top-right")
        XCTAssertTrue(isBlue(pixel(out, 25, 75)), "bottom-left")
        XCTAssertTrue(isYellow(pixel(out, 75, 75)), "bottom-right")
    }

    func testPositiveRotationIsClockwise() throws {
        let out = try DesignComposer.render(layers: [layer(rotation: 90)], canvasOuterRadiusMm: 50, outputSize: 100)
        XCTAssertTrue(isBlue(pixel(out, 25, 25)), "bottom-left moves to top-left")
        XCTAssertTrue(isRed(pixel(out, 75, 25)), "top-left moves to top-right")
        XCTAssertTrue(isYellow(pixel(out, 25, 75)), "bottom-right moves to bottom-left")
        XCTAssertTrue(isGreen(pixel(out, 75, 75)), "top-right moves to bottom-right")
    }

    func testPositiveTranslationMovesRightAndDown() throws {
        let out = try DesignComposer.render(layers: [layer(x: 25, y: 25, scale: 0.5)], canvasOuterRadiusMm: 50, outputSize: 100)
        XCTAssertEqual(pixel(out, 10, 10).a, 0, "the old top-left area is now empty")
        XCTAssertTrue(isRed(pixel(out, 62, 62)), "red quadrant of the half-size layer centred at 75,75")
        XCTAssertTrue(isYellow(pixel(out, 88, 88)))
    }

    func testFirstLayerInListIsOnTop() throws {
        let red = solid(255, 0, 0)
        let blue = solid(0, 0, 255)
        let out = try DesignComposer.render(
            layers: [layer(image: red), layer(image: blue)], canvasOuterRadiusMm: 50, outputSize: 20
        )
        XCTAssertTrue(isRed(pixel(out, 10, 10)))
    }

    func testBaseSizeFitsTheLargerSideToTheDiameter() {
        XCTAssertEqual(DesignComposer.baseSize(imageWidth: 200, imageHeight: 100, contentOuterRadiusMm: 50).width, 100)
        XCTAssertEqual(DesignComposer.baseSize(imageWidth: 200, imageHeight: 100, contentOuterRadiusMm: 50).height, 50)
        XCTAssertEqual(DesignComposer.baseSize(imageWidth: 100, imageHeight: 200, contentOuterRadiusMm: 50).width, 50)
        XCTAssertEqual(DesignComposer.baseSize(imageWidth: 100, imageHeight: 200, contentOuterRadiusMm: 50).height, 100)
    }

    func testCanvasRadiusIsFixedForCdAndFollowsGeometryOtherwise() {
        let geometry = ProjectGeometry(innerRadiusMm: 24, outerRadiusMm: 58, sectors: 32)
        XCTAssertEqual(DesignComposer.canvasOuterRadius(family: .cd, geometry: geometry), 57.5)
        XCTAssertEqual(DesignComposer.canvasOuterRadius(family: .dvd, geometry: geometry), 58)
        XCTAssertEqual(DesignComposer.canvasOuterRadius(family: .bd, geometry: geometry), 58)
    }

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGImage {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        data[0] = r; data[1] = g; data[2] = b; data[3] = 255
        return context.makeImage()!
    }
}
