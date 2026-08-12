@preconcurrency import AVFoundation
import ApplicationServices
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

private let afterRayAppBundleIdentifier = "dev.afterray.app"

private struct Options {
    let outputDirectory: URL
    let audioSegmentSeconds: Double
    let jpegQuality: Double

    static func parse(_ arguments: [String]) throws -> Self {
        var outputDirectory: URL?
        var audioSegmentSeconds = 300.0
        var jpegQuality = 0.78
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            guard index + 1 < arguments.count else {
                throw ShimError.invalidArguments("missing value for \(key)")
            }
            let value = arguments[index + 1]
            switch key {
            case "--output-dir":
                outputDirectory = URL(fileURLWithPath: value, isDirectory: true)
            case "--audio-segment-seconds":
                guard let parsed = Double(value), parsed > 0 else {
                    throw ShimError.invalidArguments("audio segment duration must be positive")
                }
                audioSegmentSeconds = parsed
            case "--jpeg-quality":
                guard let parsed = Double(value), (0 ... 1).contains(parsed) else {
                    throw ShimError.invalidArguments("JPEG quality must be between zero and one")
                }
                jpegQuality = parsed
            default:
                throw ShimError.invalidArguments("unknown option \(key)")
            }
            index += 2
        }
        guard let outputDirectory else {
            throw ShimError.invalidArguments("--output-dir is required")
        }
        return Self(
            outputDirectory: outputDirectory,
            audioSegmentSeconds: audioSegmentSeconds,
            jpegQuality: jpegQuality
        )
    }
}

private enum ShimError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case noDisplay
    case imageEncoding

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case .noDisplay: "ScreenCaptureKit did not return a display"
        case .imageEncoding: "AppKit could not encode the screenshot"
        }
    }
}

private enum ArtifactKind: String, Encodable {
    case screen
    case systemAudio = "system_audio"
    case microphone
    case accessibility
}

private struct Event: Encodable {
    let event: String
    var kind: ArtifactKind?
    var path: String?
    var contentType: String?
    var startedAtMs: Int64?
    var endedAtMs: Int64?
    var byteCount: UInt64?
    var requestId: String?
    var displayId: UInt32?
    var width: Int?
    var height: Int?
    var code: String?
    var message: String?

    enum CodingKeys: String, CodingKey {
        case event, kind, path, code, message
        case contentType = "content_type"
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case byteCount = "byte_count"
        case requestId = "request_id"
        case displayId = "display_id"
        case width, height
    }

    static func ready(display: SCDisplay) -> Self {
        Self(event: "ready", displayId: display.displayID, width: display.width, height: display.height)
    }

    static func artifact(
        kind: ArtifactKind,
        url: URL,
        startedAtMs: Int64,
        endedAtMs: Int64,
        requestId: String? = nil
    ) -> Self {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let contentType: String
        switch kind {
        case .screen: contentType = "image/jpeg"
        case .systemAudio, .microphone: contentType = "audio/mp4"
        case .accessibility: contentType = "application/vnd.afterray.ax+json"
        }
        return Self(
            event: "artifact",
            kind: kind,
            path: url.path,
            contentType: contentType,
            startedAtMs: startedAtMs,
            endedAtMs: endedAtMs,
            byteCount: size,
            requestId: requestId
        )
    }

    static func warning(code: String, message: String) -> Self {
        Self(event: "warning", code: code, message: message)
    }

    static func failed(code: String, message: String) -> Self {
        Self(event: "failed", code: code, message: message)
    }

    static let stopped = Self(event: "stopped")

    init(
        event: String,
        kind: ArtifactKind? = nil,
        path: String? = nil,
        contentType: String? = nil,
        startedAtMs: Int64? = nil,
        endedAtMs: Int64? = nil,
        byteCount: UInt64? = nil,
        requestId: String? = nil,
        displayId: UInt32? = nil,
        width: Int? = nil,
        height: Int? = nil,
        code: String? = nil,
        message: String? = nil
    ) {
        self.event = event
        self.kind = kind
        self.path = path
        self.contentType = contentType
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.byteCount = byteCount
        self.requestId = requestId
        self.displayId = displayId
        self.width = width
        self.height = height
        self.code = code
        self.message = message
    }
}

private struct AccessibilityFrame: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct AccessibilityNode: Encodable {
    let role: String?
    let subrole: String?
    let title: String?
    let nodeDescription: String?
    let identifier: String?
    let value: String?
    let valueRedacted: Bool
    let frame: AccessibilityFrame?
    let children: [AccessibilityNode]

    enum CodingKeys: String, CodingKey {
        case role, subrole, title, identifier, value, frame, children
        case nodeDescription = "description"
        case valueRedacted = "value_redacted"
    }
}

private struct AccessibilitySnapshot: Encodable {
    let capturedAtMs: Int64
    let processId: Int32
    let bundleIdentifier: String?
    let applicationName: String?
    let truncated: Bool
    let root: AccessibilityNode

    enum CodingKeys: String, CodingKey {
        case capturedAtMs = "captured_at_ms"
        case processId = "process_id"
        case bundleIdentifier = "bundle_identifier"
        case applicationName = "application_name"
        case truncated, root
    }
}

private final class AccessibilityTreeEncoder {
    private let maximumNodes = 20_000
    private var nodeCount = 0
    private var visited = Set<CFHashCode>()
    private(set) var truncated = false

    func encode(_ element: AXUIElement) -> AccessibilityNode {
        nodeCount += 1
        let identity = CFHash(element)
        guard nodeCount <= maximumNodes, visited.insert(identity).inserted else {
            truncated = true
            return AccessibilityNode(
                role: string(element, kAXRoleAttribute),
                subrole: string(element, kAXSubroleAttribute),
                title: nil,
                nodeDescription: nil,
                identifier: nil,
                value: nil,
                valueRedacted: false,
                frame: nil,
                children: []
            )
        }

        let subrole = string(element, kAXSubroleAttribute)
        let secure = subrole == "AXSecureTextField"
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .map(encode)
        return AccessibilityNode(
            role: string(element, kAXRoleAttribute),
            subrole: subrole,
            title: string(element, kAXTitleAttribute),
            nodeDescription: string(element, kAXDescriptionAttribute),
            identifier: string(element, kAXIdentifierAttribute),
            value: secure ? nil : scalarString(attribute(element, kAXValueAttribute)),
            valueRedacted: secure,
            frame: frame(element),
            children: children
        )
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        scalarString(attribute(element, name))
    }

    private func scalarString(_ value: AnyObject?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func frame(_ element: AXUIElement) -> AccessibilityFrame? {
        guard
            let positionValue = attribute(element, kAXPositionAttribute),
            let sizeValue = attribute(element, kAXSizeAttribute),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return AccessibilityFrame(
            x: position.x,
            y: position.y,
            width: size.width,
            height: size.height
        )
    }
}

private func captureAccessibilityTree(
    requestId: String,
    capturedAtMs: Int64,
    outputDirectory: URL,
    events: EventWriter
) throws {
    guard let application = capturedForegroundApplication() else {
        events.send(.warning(code: "ax_no_frontmost_app", message: "No foreground application was available"))
        return
    }
    let encoder = AccessibilityTreeEncoder()
    let root = encoder.encode(AXUIElementCreateApplication(application.processIdentifier))
    let snapshot = AccessibilitySnapshot(
        capturedAtMs: capturedAtMs,
        processId: application.processIdentifier,
        bundleIdentifier: application.bundleIdentifier,
        applicationName: application.localizedName,
        truncated: encoder.truncated,
        root: root
    )
    let url = outputDirectory
        .appendingPathComponent("accessibility-\(UUID().uuidString)")
        .appendingPathExtension("json")
    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    events.send(.artifact(
        kind: .accessibility,
        url: url,
        startedAtMs: capturedAtMs,
        endedAtMs: capturedAtMs,
        requestId: requestId
    ))
}

private func capturedForegroundApplication() -> NSRunningApplication? {
    if
        let frontmost = NSWorkspace.shared.frontmostApplication,
        frontmost.bundleIdentifier != afterRayAppBundleIdentifier
    {
        return frontmost
    }

    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for window in windows {
        guard
            (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            let processId = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            let application = NSRunningApplication(processIdentifier: processId),
            application.bundleIdentifier != afterRayAppBundleIdentifier,
            application.activationPolicy == .regular
        else { continue }
        return application
    }
    return nil
}

private final class EventWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()

    func send(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(event) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private struct SendableAssetWriter: @unchecked Sendable {
    let value: AVAssetWriter
}

private final class AudioSegmentWriter {
    private let kind: ArtifactKind
    private let outputDirectory: URL
    private let segmentDuration: Double
    private let events: EventWriter
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startedAt: CMTime?
    private var startedAtMs: Int64?
    private var outputURL: URL?

    init(kind: ArtifactKind, outputDirectory: URL, segmentDuration: Double, events: EventWriter) {
        self.kind = kind
        self.outputDirectory = outputDirectory
        self.segmentDuration = segmentDuration
        self.events = events
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let timestamp = sampleBuffer.presentationTimeStamp
        if let startedAt, CMTimeGetSeconds(timestamp - startedAt) >= segmentDuration {
            finishSegment()
        }
        if writer == nil {
            do {
                try beginSegment(sampleBuffer: sampleBuffer, timestamp: timestamp)
            } catch {
                events.send(.warning(code: "audio_writer_start", message: error.localizedDescription))
                return
            }
        }
        if input?.isReadyForMoreMediaData == true, input?.append(sampleBuffer) == false {
            events.send(.warning(code: "audio_append", message: writer?.error?.localizedDescription ?? "append failed"))
        }
    }

    func finish() {
        finishSegment(waitForCompletion: true)
    }

    private func beginSegment(sampleBuffer: CMSampleBuffer, timestamp: CMTime) throws {
        let url = outputDirectory
            .appendingPathComponent("\(kind.rawValue)-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let format = sampleBuffer.formatDescription
        let channels = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: max(1, min(Int(channels ?? 1), 2)),
            AVEncoderBitRateKey: 96_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "AfterRayCaptureShim", code: 1, userInfo: [NSLocalizedDescriptionKey: "audio input is unsupported"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "AfterRayCaptureShim", code: 2)
        }
        writer.startSession(atSourceTime: timestamp)
        self.writer = writer
        self.input = input
        startedAt = timestamp
        startedAtMs = Self.nowMs()
        outputURL = url
    }

    private func finishSegment(waitForCompletion: Bool = false) {
        guard let writer, let input, let outputURL, let startedAtMs else { return }
        self.writer = nil
        self.input = nil
        self.startedAt = nil
        self.startedAtMs = nil
        self.outputURL = nil
        input.markAsFinished()
        let completion = DispatchSemaphore(value: 0)
        let sendableWriter = SendableAssetWriter(value: writer)
        writer.finishWriting { [events, kind, sendableWriter] in
            let completedWriter = sendableWriter.value
            if completedWriter.status == .completed {
                events.send(.artifact(
                    kind: kind,
                    url: outputURL,
                    startedAtMs: startedAtMs,
                    endedAtMs: Self.nowMs()
                ))
            } else {
                events.send(.warning(
                    code: "audio_writer_finish",
                    message: completedWriter.error?.localizedDescription ?? "audio writer failed"
                ))
            }
            completion.signal()
        }
        if waitForCompletion, completion.wait(timeout: .now() + 10) == .timedOut {
            events.send(.warning(code: "audio_writer_timeout", message: "audio segment did not finish within ten seconds"))
        }
    }

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

private final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let events: EventWriter
    private let systemAudio: AudioSegmentWriter
    private let microphone: AudioSegmentWriter

    init(options: Options, events: EventWriter) {
        self.events = events
        systemAudio = AudioSegmentWriter(
            kind: .systemAudio,
            outputDirectory: options.outputDirectory,
            segmentDuration: options.audioSegmentSeconds,
            events: events
        )
        microphone = AudioSegmentWriter(
            kind: .microphone,
            outputDirectory: options.outputDirectory,
            segmentDuration: options.audioSegmentSeconds,
            events: events
        )
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            break
        case .audio:
            systemAudio.append(sampleBuffer)
        case .microphone:
            microphone.append(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_: SCStream, didStopWithError error: any Error) {
        events.send(.failed(code: "stream_stopped", message: error.localizedDescription))
    }

    func finishAudio() {
        systemAudio.finish()
        microphone.finish()
    }
}

@MainActor
private func captureScreen(
    requestId: String,
    filter: SCContentFilter,
    configuration: SCStreamConfiguration,
    options: Options,
    events: EventWriter
) async throws {
    // Screenshots are pull-based: Rust decides when a Moment is needed. The
    // native boundary does not introduce another hidden frame scheduler.
    let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
    )
    guard let data = NSBitmapImageRep(cgImage: image).representation(
        using: .jpeg,
        properties: [.compressionFactor: options.jpegQuality]
    ) else { throw ShimError.imageEncoding }
    let url = options.outputDirectory
        .appendingPathComponent("screen-\(UUID().uuidString)")
        .appendingPathExtension("jpg")
    try data.write(to: url, options: Data.WritingOptions.atomic)
    let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    events.send(.artifact(
        kind: .screen,
        url: url,
        startedAtMs: now,
        endedAtMs: now,
        requestId: requestId
    ))
    try captureAccessibilityTree(
        requestId: requestId,
        capturedAtMs: now,
        outputDirectory: options.outputDirectory,
        events: events
    )
}

private struct InputCommand: Decodable {
    let command: String
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case command
        case requestId = "request_id"
    }
}

@main
private enum AfterRayCaptureShim {
    static func main() async {
        let events = EventWriter()
        do {
            let options = try Options.parse(CommandLine.arguments)
            try FileManager.default.createDirectory(
                at: options.outputDirectory,
                withIntermediateDirectories: true
            )
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else { throw ShimError.noDisplay }

            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
            configuration.queueDepth = 3
            configuration.showsCursor = true
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.captureMicrophone = true

            let screenshotConfiguration = SCStreamConfiguration()
            screenshotConfiguration.width = display.width
            screenshotConfiguration.height = display.height
            screenshotConfiguration.showsCursor = true

            let excludedApplications = content.applications.filter {
                $0.bundleIdentifier == afterRayAppBundleIdentifier
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
            let output = CaptureOutput(options: options, events: events)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            let callbackQueue = DispatchQueue(label: "dev.afterray.capture.samples", qos: .userInitiated)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: callbackQueue)
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: callbackQueue)
            try await stream.startCapture()
            events.send(.ready(display: display))

            let decoder = JSONDecoder()
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8) else { continue }
                do {
                    let command = try decoder.decode(InputCommand.self, from: data)
                    switch command.command {
                    case "capture_screen":
                        guard let requestId = command.requestId, !requestId.isEmpty else {
                            events.send(.warning(code: "invalid_command", message: "capture_screen requires request_id"))
                            continue
                        }
                        try await captureScreen(
                            requestId: requestId,
                            filter: filter,
                            configuration: screenshotConfiguration,
                            options: options,
                            events: events
                        )
                    case "stop":
                        try await stream.stopCapture()
                        callbackQueue.sync { output.finishAudio() }
                        events.send(.stopped)
                        return
                    default:
                        events.send(.warning(code: "invalid_command", message: "unknown command \(command.command)"))
                    }
                } catch {
                    events.send(.warning(code: "command_failed", message: error.localizedDescription))
                }
            }
            try await stream.stopCapture()
            callbackQueue.sync { output.finishAudio() }
            events.send(.stopped)
        } catch {
            events.send(.failed(code: "startup", message: String(describing: error)))
            Foundation.exit(EXIT_FAILURE)
        }
    }
}
