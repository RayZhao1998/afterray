#!/usr/bin/env swift

import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

struct Row {
    var name: String
    var medianMs: Double
    var p95Ms: Double
}

let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/afterray-bench/desktop.jpg")
let jpeg = try Data(contentsOf: url)
guard let baseline = imageIO(jpeg, cacheImmediately: true) else {
    fputs("could not decode \(url.path)\n", stderr)
    exit(1)
}

let pixels = baseline.width * baseline.height
print("source: \(url.path)")
print("jpeg: \(kb(jpeg.count)), \(baseline.width)x\(baseline.height) = \(String(format: "%.2f", Double(pixels) / 1_000_000)) MP")
print("RGBA32 bitmap: \(kb(pixels * 4))")
print()

var rows: [Row] = []

rows.append(measure("ImageIO cacheImmediately (current)") {
    _ = imageIO(jpeg, cacheImmediately: true)
})
rows.append(measure("ImageIO create only, no cache") {
    _ = imageIO(jpeg, cacheImmediately: false)
})
rows.append(measure("ImageIO then force-render via CGContext") {
    guard let image = imageIO(jpeg, cacheImmediately: false) else { return }
    forceDraw(image)
})
rows.append(measure("NSImage(data:) construct only") {
    _ = NSImage(data: jpeg)
})
rows.append(measure("NSImage(data:) + lockFocus draw") {
    guard let image = NSImage(data: jpeg) else { return }
    image.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    image.unlockFocus()
})
rows.append(measure("ImageIO thumbnail 1728px (half long edge)") {
    _ = imageIOThumbnail(jpeg, maxPixelSize: 1728)
})
rows.append(measure("ImageIO thumbnail 480px") {
    _ = imageIOThumbnail(jpeg, maxPixelSize: 480)
})

let metalContext = CIContext(options: [
    .useSoftwareRenderer: false,
    .cacheIntermediates: false,
])
let softwareContext = CIContext(options: [
    .useSoftwareRenderer: true,
    .cacheIntermediates: false,
])
rows.append(measure("CIImage(data) construct only") {
    _ = CIImage(data: jpeg)
})
rows.append(measure("CIImage + Metal CIContext render RGBA") {
    guard let input = CIImage(data: jpeg) else { return }
    _ = metalContext.createCGImage(input, from: input.extent)
})
rows.append(measure("CIImage + software CIContext render RGBA") {
    guard let input = CIImage(data: jpeg) else { return }
    _ = softwareContext.createCGImage(input, from: input.extent)
})

if let decoder = VideoToolboxJPEGDecoder(width: baseline.width, height: baseline.height) {
    print("VideoToolbox hardware decode: \(decoder.usingHardware ? "yes" : "no / unknown")")
    rows.append(measure("VideoToolbox JPEG -> CVPixelBuffer") {
        _ = decoder.decode(jpeg)
    })
    rows.append(measure("VideoToolbox + CIImage(cvPixelBuffer) only") {
        guard let buffer = decoder.decode(jpeg) else { return }
        _ = CIImage(cvPixelBuffer: buffer)
    })
    rows.append(measure("VideoToolbox + Metal render RGBA") {
        guard let buffer = decoder.decode(jpeg) else { return }
        let input = CIImage(cvPixelBuffer: buffer)
        _ = metalContext.createCGImage(input, from: input.extent)
    })
} else {
    print("VideoToolbox JPEG session unavailable")
}

print()
print(pad("path", 48) + pad("median", 10, right: true) + " " + pad("p95", 10, right: true))
print(String(repeating: "-", count: 70))
for row in rows {
    print(
        pad(row.name, 48)
            + pad(String(format: "%.2fms", row.medianMs), 10, right: true)
            + " "
            + pad(String(format: "%.2fms", row.p95Ms), 10, right: true)
    )
}

func imageIO(_ data: Data, cacheImmediately: Bool) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    var options: [CFString: Any] = [:]
    if cacheImmediately {
        options[kCGImageSourceShouldCacheImmediately] = true
    }
    return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
}

func imageIOThumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func forceDraw(_ image: CGImage) {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    pixels.withUnsafeMutableBytes { raw in
        guard
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

final class VideoToolboxJPEGDecoder {
    let session: VTDecompressionSession
    let format: CMVideoFormatDescription
    let usingHardware: Bool

    init?(width: Int, height: Int) {
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_JPEG,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else { return nil }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue as Any,
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { return nil }
        self.format = format
        self.session = session
        var hardware: CFBoolean?
        var infoSize = MemoryLayout<CFBoolean?>.size
        if VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &hardware
        ) == noErr, let hardware {
            usingHardware = CFBooleanGetValue(hardware)
        } else {
            usingHardware = false
        }
        _ = infoSize
    }

    func decode(_ jpeg: Data) -> CVPixelBuffer? {
        var block: CMBlockBuffer?
        let copied = jpeg as NSData
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: copied.bytes),
            blockLength: copied.count,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: copied.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard blockStatus == noErr, let block else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = copied.count
        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { return nil }

        var imageBuffer: CVImageBuffer?
        var flagsOut = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: &flagsOut
        ) { _, _, buffer, _, _ in
            imageBuffer = buffer
        }
        guard decodeStatus == noErr else { return nil }
        return imageBuffer
    }
}

func measure(_ name: String, rounds: Int = 11, warmup: Int = 2, body: () -> Void) -> Row {
    fputs("  \(name)\n", stderr)
    for _ in 0..<warmup { body() }
    var samples: [Double] = []
    for _ in 0..<rounds {
        let started = CFAbsoluteTimeGetCurrent()
        body()
        samples.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
    }
    samples.sort()
    return Row(
        name: name,
        medianMs: samples[samples.count / 2],
        p95Ms: samples[(samples.count * 95) / 100]
    )
}

func kb(_ bytes: Int) -> String {
    String(format: "%.1f KB", Double(bytes) / 1024.0)
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    if text.count >= width { return text }
    let padding = String(repeating: " ", count: width - text.count)
    return right ? padding + text : text + padding
}
