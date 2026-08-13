#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO

struct Row {
    var name: String
    var medianMs: Double
    var p95Ms: Double
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/afterray-bench/desktop.jpg")
let sourceData = try Data(contentsOf: sourceURL)
guard let pixels = decode(sourceData, cacheImmediately: true) else {
    fputs("could not decode \(sourceURL.path)\n", stderr)
    exit(1)
}

print("source: \(sourceURL.path)")
print("pixels: \(pixels.width)x\(pixels.height)")
print("source file: \(kb(sourceData.count))")
print()

let codecs: [(String, CFString, [CFString: Any])] = [
    ("JPEG q=0.95 (current)", "public.jpeg" as CFString, [kCGImageDestinationLossyCompressionQuality: 0.95]),
    ("JPEG q=0.80", "public.jpeg" as CFString, [kCGImageDestinationLossyCompressionQuality: 0.80]),
    ("JPEG q=0.60", "public.jpeg" as CFString, [kCGImageDestinationLossyCompressionQuality: 0.60]),
    ("PNG", "public.png" as CFString, [:]),
    ("HEIC q=0.80", "public.heic" as CFString, [kCGImageDestinationLossyCompressionQuality: 0.80]),
]

var encoded: [(String, Data)] = []
var rows: [Row] = []

for (name, uti, options) in codecs {
    let payload = encode(pixels, uti: uti, options: options)
    if payload.isEmpty {
        print("skip \(name): encoder unavailable")
        continue
    }
    encoded.append((name, payload))
    let out = URL(fileURLWithPath: "/tmp/afterray-bench/desktop-\(slug(name))")
    try payload.write(to: out)
    print("\(pad(name, 24)) \(kb(payload.count))  -> \(out.lastPathComponent)")
}

print()
print("encode from the same \(pixels.width)x\(pixels.height) bitmap")
for (name, uti, options) in codecs {
    let sample = encoded.first(where: { $0.0 == name })?.1
    guard sample != nil else { continue }
    rows.append(measure("encode \(name)") {
        _ = encode(pixels, uti: uti, options: options)
    })
}

print()
print("decode back to pixels (ShouldCacheImmediately, same as Recall)")
for (name, data) in encoded {
    rows.append(measure("decode \(name)") {
        _ = decode(data, cacheImmediately: true)
    })
}

print()
print("decode thumbnail max-edge 480")
for (name, data) in encoded {
    rows.append(measure("thumb480 \(name)") {
        _ = decodeThumbnail(data, maxPixelSize: 480)
    })
}

print()
print("NSBitmapImageRep encode (capture shim path)")
rows.append(measure("NSBitmap JPEG q=0.95") {
    _ = nsEncode(pixels, using: .jpeg, quality: 0.95)
})
rows.append(measure("NSBitmap PNG") {
    _ = nsEncode(pixels, using: .png, quality: 1)
})

print()
print(pad("stage", 40) + pad("median", 10, right: true) + " " + pad("p95", 10, right: true))
print(String(repeating: "-", count: 62))
for row in rows {
    print(
        pad(row.name, 40)
            + pad(String(format: "%.2fms", row.medianMs), 10, right: true)
            + " "
            + pad(String(format: "%.2fms", row.p95Ms), 10, right: true)
    )
}

func encode(_ image: CGImage, uti: CFString, options: [CFString: Any]) -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, uti, 1, nil) else { return Data() }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return Data() }
    return data as Data
}

func decode(_ data: Data, cacheImmediately: Bool) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    var options: [CFString: Any] = [:]
    if cacheImmediately {
        options[kCGImageSourceShouldCacheImmediately] = true
    }
    return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
}

func decodeThumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func nsEncode(_ image: CGImage, using format: NSBitmapImageRep.FileType, quality: Double) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    var properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
    if format == .jpeg {
        properties[.compressionFactor] = quality
    }
    return rep.representation(using: format, properties: properties)
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

func slug(_ name: String) -> String {
    let ext: String
    if name.contains("PNG") { ext = "png" }
    else if name.contains("HEIC") { ext = "heic" }
    else { ext = "jpg" }
    return name.lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: "=", with: "")
        + "." + ext
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    if text.count >= width { return text }
    let padding = String(repeating: " ", count: width - text.count)
    return right ? padding + text : text + padding
}
