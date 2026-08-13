#!/usr/bin/env swift

import AppKit
import CoreImage
import Foundation
import ImageIO

struct Row {
    var name: String
    var medianMs: Double
    var p95Ms: Double
    var meanMs: Double
}

struct Fixture {
    var label: String
    var jpeg: Data
    var pixelSize: CGSize
}

enum FixtureStyle {
    case busy
    case ui
}

log("generating fixtures")

let outputDirectory = URL(fileURLWithPath: "/tmp/afterray-bench", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let busy = try makeFixture(
    label: "busy retina JPEG",
    width: 3024,
    height: 1964,
    style: .busy,
    destination: outputDirectory.appendingPathComponent("busy.jpg")
)
let ui = try makeFixture(
    label: "flat UI JPEG",
    width: 3024,
    height: 1964,
    style: .ui,
    destination: outputDirectory.appendingPathComponent("ui.jpg")
)

print()
print("=== afterray client artifact stages ===")
print("fixtures written to \(outputDirectory.path)")
for fixture in [busy, ui] {
    print(
        "- \(fixture.label) : \(String(format: "%.1f", Double(fixture.jpeg.count) / 1024.0)) KB, \(Int(fixture.pixelSize.width))x\(Int(fixture.pixelSize.height))"
    )
}

for fixture in [busy, ui] {
    print()
    print("—— \(fixture.label) ——")
    printTable(benchClient(fixture: fixture))
}

print()
print("—— UI chrome (independent of image size) ——")
printTable(benchChrome())

func makeFixture(
    label: String,
    width: Int,
    height: Int,
    style: FixtureStyle,
    destination: URL
) throws -> Fixture {
    log("drawing \(label)")
    let size = NSSize(width: width, height: height)
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
        throw NSError(domain: "afterray.bench", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "could not allocate bitmap for \(label)",
        ])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    switch style {
    case .busy:
        NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.08, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 72, height: size.height).fill()
        NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1).setFill()
        NSRect(x: 72, y: size.height - 52, width: size.width - 72, height: 52).fill()
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1).setFill()
        NSRect(x: 120, y: 84, width: size.width / 2, height: size.height - 180).fill()
        NSColor(calibratedRed: 0.22, green: 0.09, blue: 0.10, alpha: 1).setFill()
        NSRect(x: size.width / 2 + 160, y: size.height / 3, width: size.width / 3, height: size.height / 2).fill()
        var seed: UInt64 = 0xC0FF_EE12_3456_789A
        for row in 0..<36 {
            for column in 0..<80 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let gray = CGFloat((seed >> 33) & 255) / 255.0
                NSColor(calibratedWhite: gray, alpha: 1).setFill()
                NSRect(
                    x: 160 + CGFloat(column) * 12,
                    y: size.height / 3 + CGFloat(row) * 8,
                    width: 11,
                    height: 7
                ).fill()
            }
        }
    case .ui:
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - 88, width: size.width, height: 88).fill()
        NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1).setFill()
        NSRect(x: 80, y: 120, width: size.width - 160, height: size.height - 280).fill()
        NSColor(calibratedRed: 0.86, green: 0.19, blue: 0.16, alpha: 1).setFill()
        NSRect(x: 120, y: size.height - 250, width: 420, height: 36).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    if style == .busy, let data = rep.bitmapData {
        let rowBytes = rep.bytesPerRow
        let noiseTop = height / 3
        let noiseHeight = height / 4
        for row in noiseTop..<(noiseTop + noiseHeight) {
            let start = data + row * rowBytes + 160 * 4
            let count = (width - 320) * 4
            guard count > 0 else { continue }
            arc4random_buf(start, count)
            var offset = 3
            while offset < count {
                start[offset] = 255
                offset += 4
            }
        }
    }
    log("encoding \(label)")
    guard
        let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    else {
        throw NSError(domain: "afterray.bench", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not encode \(label)",
        ])
    }
    try jpeg.write(to: destination)
    log("wrote \(destination.path) \(jpeg.count) bytes")
    return Fixture(label: label, jpeg: jpeg, pixelSize: size)
}

func benchClient(fixture: Fixture) -> [Row] {
    log("bench \(fixture.label)")
    let artifactID = "bench-artifact"
    let payloadJSON: Data = {
        let object: [String: Any] = [
            "protocol_version": 1,
            "ok": true,
            "data": [
                "id": artifactID,
                "content_type": "image/jpeg",
                "bytes_base64": fixture.jpeg.base64EncodedString(),
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }()
    var line = payloadJSON
    line.append(0x0A)

    print(
        "json line: \(String(format: "%.1f", Double(line.count) / 1024.0)) KB (\(String(format: "%.0f", Double(line.count) / Double(fixture.jpeg.count) * 100.0))% of jpeg)"
    )

    let base64 = fixture.jpeg.base64EncodedString()
    let decoded = decodeJPEG(fixture.jpeg)!
    let blurContext = CIContext(options: [.useSoftwareRenderer: false])

    var rows: [Row] = []
    rows.append(measure("base64 encode jpeg (daemon-equivalent)") {
        _ = fixture.jpeg.base64EncodedString()
    })
    rows.append(measure("JSONSerialization make response from pre-encoded b64") {
        let object: [String: Any] = [
            "protocol_version": 1,
            "ok": true,
            "data": [
                "id": artifactID,
                "content_type": "image/jpeg",
                "bytes_base64": base64,
            ],
        ]
        _ = try! JSONSerialization.data(withJSONObject: object)
    })
    rows.append(measure("JSONSerialization.jsonObject full response") {
        _ = try! JSONSerialization.jsonObject(with: payloadJSON)
    })
    rows.append(measure("re-serialize data + JSONDecoder ArtifactPayload") {
        let object = try! JSONSerialization.jsonObject(with: payloadJSON) as! [String: Any]
        let nested = try! JSONSerialization.data(withJSONObject: object["data"]!)
        _ = try! JSONDecoder().decode(SimulatedPayload.self, from: nested)
    })
    rows.append(measure("Data(base64Encoded:) only") {
        _ = Data(base64Encoded: base64)
    })
    rows.append(measure("client ingest: parse JSON + b64 + JPEG decode + NSImage") {
        let object = try! JSONSerialization.jsonObject(with: payloadJSON) as! [String: Any]
        let nested = try! JSONSerialization.data(withJSONObject: object["data"]!)
        let payload = try! JSONDecoder().decode(SimulatedPayload.self, from: nested)
        let bytes = Data(base64Encoded: payload.bytesBase64)!
        let image = decodeJPEG(bytes)!
        _ = NSImage(cgImage: image, size: .zero)
    })
    rows.append(measure("JPEG decode (ShouldCacheImmediately)") {
        _ = decodeJPEG(fixture.jpeg)
    })
    rows.append(measure("JPEG decode thumbnail 480px") {
        _ = decodeJPEGThumbnail(fixture.jpeg, maxPixelSize: 480)
    })
    rows.append(measure("NSImage wrap decoded CGImage") {
        _ = NSImage(cgImage: decoded, size: .zero)
    })
    rows.append(measure("CIFilter gaussianBlur radius 42 + render [removed]") {
        renderBlur(decoded, radius: 42, context: blurContext)
    })
    return rows
}

func benchChrome() -> [Row] {
    let bundles = [
        "com.apple.dt.Xcode",
        "com.apple.Safari",
        "com.apple.Finder",
        "com.apple.Terminal",
        "com.apple.TextEdit",
        "com.apple.Preview",
        "com.apple.Music",
        "com.apple.Notes",
        "com.apple.mail",
        "com.apple.iCal",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
    ]
    var rows: [Row] = []
    rows.append(measure("NSWorkspace icon lookup x1") {
        lookupIcon(bundleIdentifier: bundles[0])
    })
    rows.append(measure("NSWorkspace icon lookup x12 unique") {
        for bundle in bundles {
            lookupIcon(bundleIdentifier: bundle)
        }
    })
    rows.append(measure("NSWorkspace icon lookup x50 mixed") {
        for index in 0..<50 {
            lookupIcon(bundleIdentifier: bundles[index % bundles.count])
        }
    })
    return rows
}

struct SimulatedPayload: Decodable {
    let id: String
    let contentType: String
    let bytesBase64: String

    enum CodingKeys: String, CodingKey {
        case id
        case contentType = "content_type"
        case bytesBase64 = "bytes_base64"
    }
}

func decodeJPEG(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
    return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
}

func decodeJPEGThumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

func renderBlur(_ image: CGImage, radius: Double, context: CIContext) {
    let input = CIImage(cgImage: image)
    let blurred = input
        .clampedToExtent()
        .applyingGaussianBlur(sigma: radius)
        .cropped(to: input.extent)
    _ = context.createCGImage(blurred, from: input.extent)
}

func lookupIcon(bundleIdentifier: String) {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
    _ = NSWorkspace.shared.icon(forFile: url.path)
}

func measure(_ name: String, rounds: Int = 17, warmup: Int = 3, body: () -> Void) -> Row {
    log("  \(name)")
    for _ in 0..<warmup {
        body()
    }
    var samples: [Double] = []
    samples.reserveCapacity(rounds)
    for _ in 0..<rounds {
        let started = CFAbsoluteTimeGetCurrent()
        body()
        samples.append((CFAbsoluteTimeGetCurrent() - started) * 1_000)
    }
    samples.sort()
    let mean = samples.reduce(0, +) / Double(samples.count)
    return Row(
        name: name,
        medianMs: samples[samples.count / 2],
        p95Ms: samples[(samples.count * 95) / 100],
        meanMs: mean
    )
}

func printTable(_ rows: [Row]) {
    print("\(pad("stage", 62)) \(pad("median", 10, right: true)) \(pad("p95", 10, right: true)) \(pad("mean", 10, right: true))")
    print(String(repeating: "-", count: 96))
    for row in rows {
        print(
            "\(pad(row.name, 62)) \(pad(String(format: "%.2fms", row.medianMs), 10, right: true)) \(pad(String(format: "%.2fms", row.p95Ms), 10, right: true)) \(pad(String(format: "%.2fms", row.meanMs), 10, right: true))"
        )
    }
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    if text.count >= width { return text }
    let padding = String(repeating: " ", count: width - text.count)
    return right ? padding + text : text + padding
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
