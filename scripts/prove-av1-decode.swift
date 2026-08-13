#!/usr/bin/env swift
// Prove PR 4: a rav1e closed-GOP IVF can be decoded to NV12 on this Mac.
//
// Path A (preferred): IVF demux → OBU → VideoToolbox kCMVideoCodecType_AV1
// Path B (fallback):  ffmpeg -c copy IVF→MP4 → AVAssetReader → NV12
//
// Usage:
//   swift scripts/prove-av1-decode.swift [path/to/closed-gop.ivf]
// Exit 0 iff at least one frame decodes with non-zero width and height.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let kCMVideoCodecTypeAV1: CMVideoCodecType = 0x6176_3031 // 'av01'

struct ProofError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct IvfFrame {
    let pts: UInt64
    let data: Data
}

struct Ivf {
    let width: Int
    let height: Int
    let frames: [IvfFrame]
}

struct OBU {
    let type: UInt8
    let raw: Data
    let payload: Data
}

struct DecodedFrame {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    let path: String
}

func main() {
    do {
        let ivfURL = try resolveIVF()
        let ivfData = try Data(contentsOf: ivfURL)
        let ivf = try parseIVF(ivfData)
        print("ivf: \(ivfURL.path)")
        print("ivf header: \(hex(ivfData.prefix(32)))")
        print("ivf size: \(ivf.width)x\(ivf.height) frames=\(ivf.frames.count) bytes=\(ivfData.count)")
        guard ivf.width > 0, ivf.height > 0, ivf.frames.count > 1 else {
            throw ProofError("IVF must have non-zero size and >1 frame")
        }
        if !ivfData.starts(with: Data("DKIF".utf8)) {
            throw ProofError("IVF magic is not DKIF")
        }

        var decoded: DecodedFrame?
        var failures: [String] = []

        do {
            decoded = try decodeWithVideoToolbox(ivf: ivf, raw: ivfData)
        } catch {
            failures.append("VideoToolbox: \(error)")
        }

        if decoded == nil {
            do {
                decoded = try decodeWithRemuxedMP4(ivfURL: ivfURL)
            } catch {
                failures.append("AVAssetReader(mp4 remux): \(error)")
            }
        }

        guard let decoded else {
            fputs("FAIL: no decode path produced NV12\n", stderr)
            for line in failures {
                fputs("  - \(line)\n", stderr)
            }
            exit(1)
        }

        print("path: \(decoded.path)")
        print("frame: \(decoded.width)x\(decoded.height) pixel_format=\(fourCC(decoded.pixelFormat))")
        print("ok")
        exit(0)
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(1)
    }
}

func resolveIVF() throws -> URL {
    if let arg = CommandLine.arguments.dropFirst().first {
        return URL(fileURLWithPath: arg)
    }
    let here = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let scriptDir = here.deletingLastPathComponent()
    let candidates = [
        scriptDir.deletingLastPathComponent()
            .appendingPathComponent("crates/afterray-codec/fixtures/closed-gop-64x64.ivf"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("crates/afterray-codec/fixtures/closed-gop-64x64.ivf"),
    ]
    if let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        return hit
    }
    throw ProofError("missing IVF fixture; pass a path or run from the repo root")
}

func parseIVF(_ data: Data) throws -> Ivf {
    guard data.count >= 32, data.starts(with: Data("DKIF".utf8)) else {
        throw ProofError("not an IVF (missing DKIF)")
    }
    let width = Int(readU16LE(data, 12))
    let height = Int(readU16LE(data, 14))
    var frames: [IvfFrame] = []
    var offset = 32
    while offset + 12 <= data.count {
        let size = Int(readU32LE(data, offset))
        let pts = readU64LE(data, offset + 4)
        let start = offset + 12
        let end = start + size
        guard end <= data.count else {
            throw ProofError("truncated IVF frame \(frames.count)")
        }
        frames.append(IvfFrame(pts: pts, data: data.subdata(in: start..<end)))
        offset = end
    }
    return Ivf(width: width, height: height, frames: frames)
}

func parseOBUs(_ data: Data) -> [OBU] {
    var obus: [OBU] = []
    var i = 0
    let bytes = [UInt8](data)
    while i < bytes.count {
        let headerStart = i
        let b = bytes[i]
        i += 1
        let type = (b >> 3) & 0x0F
        let ext = (b & 0x04) != 0
        let hasSize = (b & 0x02) != 0
        if ext {
            guard i < bytes.count else { break }
            i += 1
        }
        let size: Int
        if hasSize {
            var value = 0
            var shift = 0
            var ok = false
            while i < bytes.count {
                let leb = bytes[i]
                i += 1
                value |= Int(leb & 0x7F) << shift
                if leb & 0x80 == 0 {
                    ok = true
                    break
                }
                shift += 7
                if shift > 28 { break }
            }
            guard ok else { break }
            size = value
        } else {
            size = bytes.count - i
        }
        guard i + size <= bytes.count else { break }
        let payload = Data(bytes[i..<(i + size)])
        let raw = Data(bytes[headerStart..<(i + size)])
        obus.append(OBU(type: type, raw: raw, payload: payload))
        i += size
    }
    return obus
}

func makeAv1C(from firstFrame: Data) -> Data? {
    let obus = parseOBUs(firstFrame)
    guard let seq = obus.first(where: { $0.type == 1 }) else { return nil }
    let payload = [UInt8](seq.payload)
    guard let first = payload.first else { return nil }
    let profile = first >> 5
    // Conservative 8-bit 4:2:0 Main. Level 2.0 (idx 0) is enough for 64x64;
    // VT still sees the real sequence header in configOBUs.
    var av1c = Data()
    av1c.append(0x81) // marker=1, version=1
    av1c.append((profile << 5) | 0x00) // seq_level_idx_0 = 0
    av1c.append(0x0C) // 4:2:0, 8-bit, no tier
    av1c.append(0x00) // no initial_presentation_delay
    av1c.append(seq.raw)
    return av1c
}

func stripTemporalDelimiters(_ frame: Data) -> Data {
    let obus = parseOBUs(frame)
    if obus.isEmpty { return frame }
    var out = Data()
    for obu in obus where obu.type != 2 {
        out.append(obu.raw)
    }
    return out.isEmpty ? frame : out
}

func decodeWithVideoToolbox(ivf: Ivf, raw: Data) throws -> DecodedFrame {
    guard let av1c = makeAv1C(from: ivf.frames[0].data) else {
        throw ProofError("no sequence header OBU in first IVF frame")
    }
    print("av1C: \(hex(av1c.prefix(16)))… (\(av1c.count) bytes)")

    let atoms: [String: Data] = ["av1C": av1c]
    let extensions: [CFString: Any] = [
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
    ]
    var format: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        codecType: kCMVideoCodecTypeAV1,
        width: Int32(ivf.width),
        height: Int32(ivf.height),
        extensions: extensions as CFDictionary,
        formatDescriptionOut: &format
    )
    guard formatStatus == noErr, let format else {
        throw ProofError("CMVideoFormatDescriptionCreate av01 failed: \(formatStatus)")
    }

    let pixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]
    var lastError = "no pixel format accepted"
    for pixelFormat in pixelFormats {
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: kCFBooleanTrue as Any,
            ] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            ] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            lastError = "VTDecompressionSessionCreate \(fourCC(pixelFormat)) status=\(status)"
            continue
        }
        defer { VTDecompressionSessionInvalidate(session) }

        var decoded: CVPixelBuffer?
        var decodeError: String?
        for (index, frame) in ivf.frames.enumerated() {
            let sampleData = stripTemporalDelimiters(frame.data)
            guard let sample = makeSample(sampleData, format: format, pts: frame.pts) else {
                decodeError = "could not wrap IVF frame \(index) as CMSampleBuffer"
                break
            }
            var infoFlags = VTDecodeInfoFlags()
            var imageBuffer: CVImageBuffer?
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: &infoFlags
            ) { status, _, buffer, _, _ in
                if status == noErr {
                    imageBuffer = buffer
                }
            }
            if decodeStatus != noErr {
                decodeError = "DecodeFrame[\(index)] status=\(decodeStatus)"
                break
            }
            let finish = VTDecompressionSessionWaitForAsynchronousFrames(session)
            if finish != noErr {
                decodeError = "WaitForAsynchronousFrames[\(index)] status=\(finish)"
                break
            }
            if let imageBuffer {
                decoded = imageBuffer
            }
        }
        if let decoded {
            let width = CVPixelBufferGetWidth(decoded)
            let height = CVPixelBufferGetHeight(decoded)
            guard width > 0, height > 0 else {
                throw ProofError("VT produced a 0-size buffer")
            }
            return DecodedFrame(
                width: width,
                height: height,
                pixelFormat: CVPixelBufferGetPixelFormatType(decoded),
                path: "VideoToolbox kCMVideoCodecType_AV1 IVF/OBU"
            )
        }
        lastError = decodeError ?? lastError
    }
    throw ProofError(lastError)
}

func makeSample(_ data: Data, format: CMFormatDescription, pts: UInt64) -> CMSampleBuffer? {
    var block: CMBlockBuffer?
    let createStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: data.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: data.count,
        flags: 0,
        blockBufferOut: &block
    )
    guard createStatus == noErr, let block else { return nil }
    let replaceStatus = data.withUnsafeBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return -1 }
        return CMBlockBufferReplaceDataBytes(
            with: base,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: data.count
        )
    }
    guard replaceStatus == noErr else { return nil }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 1),
        presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1),
        decodeTimeStamp: .invalid
    )
    var sampleSize = data.count
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
    guard sampleStatus == noErr else { return nil }
    return sample
}

func decodeWithRemuxedMP4(ivfURL: URL) throws -> DecodedFrame {
    let ffmpeg = resolveFFmpeg()
    let mp4URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("afterray-av1-proof-\(ProcessInfo.processInfo.processIdentifier).mp4")
    if FileManager.default.fileExists(atPath: mp4URL.path) {
        try FileManager.default.removeItem(at: mp4URL)
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: ffmpeg)
    proc.arguments = ["-y", "-hide_banner", "-loglevel", "error", "-i", ivfURL.path, "-c", "copy", mp4URL.path]
    let err = Pipe()
    proc.standardError = err
    proc.standardOutput = Pipe()
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw ProofError("ffmpeg remux failed (\(proc.terminationStatus)): \(msg)")
    }
    defer { try? FileManager.default.removeItem(at: mp4URL) }

    let asset = AVURLAsset(url: mp4URL)
    let tracks = asset.tracks(withMediaType: .video)
    guard let track = tracks.first else {
        throw ProofError("remuxed MP4 has no video track")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw ProofError("AVAssetReader cannot add NV12 track output")
    }
    reader.add(output)
    guard reader.startReading() else {
        throw ProofError("AVAssetReader.startReading failed: \(reader.error?.localizedDescription ?? "unknown")")
    }
    var last: CVPixelBuffer?
    var count = 0
    while let sample = output.copyNextSampleBuffer() {
        if let image = CMSampleBufferGetImageBuffer(sample) {
            last = image
            count += 1
        }
    }
    guard let last, count > 0 else {
        throw ProofError("AVAssetReader produced no pixel buffers (status=\(reader.status.rawValue))")
    }
    let width = CVPixelBufferGetWidth(last)
    let height = CVPixelBufferGetHeight(last)
    guard width > 0, height > 0 else {
        throw ProofError("AVAssetReader produced a 0-size buffer")
    }
    print("remux: \(mp4URL.path) frames=\(count)")
    return DecodedFrame(
        width: width,
        height: height,
        pixelFormat: CVPixelBufferGetPixelFormatType(last),
        path: "ffmpeg -c copy IVF→MP4 + AVAssetReader NV12"
    )
}

func resolveFFmpeg() -> String {
    for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return "ffmpeg"
}

func readU16LE(_ data: Data, _ offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
}

func readU32LE(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
}

func readU64LE(_ data: Data, _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
        value |= UInt64(data[offset + i]) << (8 * i)
    }
    return value
}

func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

func fourCC(_ value: OSType) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    if bytes.allSatisfy({ (32...126).contains($0) }) {
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }
    return String(format: "0x%08x", value)
}

main()
