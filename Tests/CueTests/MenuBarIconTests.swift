import CoreGraphics
import Foundation
import ImageIO
import Testing

/// macOS draws a template image from its alpha channel alone, so an opaque
/// background renders as a solid square in the menu bar.
struct MenuBarIconTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources")

    @Test(arguments: [("MenuBarIconTemplate.png", 18), ("MenuBarIconTemplate@2x.png", 36)])
    func templateIconIsAGlyphOnATransparentBackground(name: String, side: Int) throws {
        let url = Self.resources.appendingPathComponent(name)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == side)
        #expect(image.height == side)

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = try #require(
            CGContext(
                data: &pixels, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let alphas = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }

        let transparent = alphas.filter { $0 == 0 }.count
        let opaque = alphas.filter { $0 == 255 }.count
        // The corners are background and must be fully transparent.
        #expect([alphas[0], alphas[side - 1], alphas[side * (side - 1)], alphas[side * side - 1]] == [0, 0, 0, 0])
        // Most of the canvas is background; the glyph still has solid strokes.
        #expect(transparent > alphas.count / 2)
        #expect(opaque > 0)
    }
}
