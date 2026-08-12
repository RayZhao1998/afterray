import AppKit
import CoreVideo
import XCTest
@testable import AfterRayRecall

final class RecallYUVDisplayTests: XCTestCase {
    func testJPEGMagicAndPixelSize() throws {
        let jpeg = try encodeJPEG(width: 64, height: 48, color: .red)
        XCTAssertTrue(RecallFrameDecoder.isJPEG(jpeg))
        let size = try XCTUnwrap(RecallFrameDecoder.pixelSize(of: jpeg))
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 48)
    }

    func testJPEGDecodesToPixelBuffer() throws {
        let jpeg = try encodeJPEG(width: 128, height: 80, color: .blue)
        let frame = try XCTUnwrap(RecallFrameDecoder.decode(jpeg))
        let buffer = try XCTUnwrap(frame.pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 80)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
        XCTAssertNil(frame.fallbackImage)
    }

    func testNonJPEGFallsBackToImageIO() throws {
        let png = try encodePNG(width: 32, height: 24, color: .green)
        XCTAssertFalse(RecallFrameDecoder.isJPEG(png))
        let frame = try XCTUnwrap(RecallFrameDecoder.decode(png))
        XCTAssertNil(frame.pixelBuffer)
        let image = try XCTUnwrap(frame.fallbackImage)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 24)
    }

    private func encodeJPEG(width: Int, height: Int, color: NSColor) throws -> Data {
        try encode(width: width, height: height, color: color, format: .jpeg, quality: 0.8)
    }

    private func encodePNG(width: Int, height: Int, color: NSColor) throws -> Data {
        try encode(width: width, height: height, color: color, format: .png, quality: 1)
    }

    private func encode(
        width: Int,
        height: Int,
        color: NSColor,
        format: NSBitmapImageRep.FileType,
        quality: Double
    ) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
        if format == .jpeg {
            properties[.compressionFactor] = quality
        }
        guard let data = rep.representation(using: format, properties: properties) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }
}
