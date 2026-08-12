import AfterRayRecall
import AppKit
import Foundation

public enum RecallScenario: String, CaseIterable, Identifiable, Sendable {
    case empty
    case short
    case long
    case processing
    case favorites

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .empty: "Empty"
        case .short: "Short"
        case .long: "Long day"
        case .processing: "Processing"
        case .favorites: "Favorites"
        }
    }

    public var moments: [RecallMoment] {
        switch self {
        case .empty: []
        case .short: Self.makeMoments(count: 7)
        case .long: Self.makeMoments(count: 84)
        case .processing: Self.makeMoments(count: 11, processing: true)
        case .favorites: Self.makeMoments(count: 22, favoriteEvery: 4)
        }
    }

    public var loadState: RecallLoadState {
        self == .processing ? .processing(message: "OCR and transcript are catching up") : .ready
    }

    private static func makeMoments(
        count: Int,
        processing: Bool = false,
        favoriteEvery: Int? = nil
    ) -> [RecallMoment] {
        let base = Int64(1_786_483_800_000)
        let screenCopy = [
            "Reviewing the capture pipeline and its retry policy.",
            "Timeline interaction: drag horizontally to move through the day.",
            "The local model queue is idle and all artifacts are available.",
            "Comparing layout options for the first Recall experience.",
        ]
        let transcriptCopy = [
            "Let's keep the first version narrow and make the core interaction feel exceptional.",
            "The daemon should own storage while the interface stays replaceable.",
            "We can validate this with a real day of recording before adding more product surface.",
        ]
        let applications = [
            ("Figma", "com.figma.Desktop"),
            ("Safari", "com.apple.Safari"),
            ("Xcode", "com.apple.dt.Xcode"),
            ("Slack", "com.tinyspeck.slackmacgap"),
            ("Notion", "notion.id"),
        ]
        return (0..<count).map { index in
            let app = applications[min(index / 7, applications.count - 1) % applications.count]
            return RecallMoment(
                id: "moment-\(index)",
                sessionId: "session-today",
                capturedAtMs: base + Int64(index * 42_000),
                imageArtifactId: "mock://frame/\(index)",
                isFavorite: favoriteEvery.map { index.isMultiple(of: $0) } ?? false,
                ocrText: processing && index > count - 4 ? nil : screenCopy[index % screenCopy.count],
                transcriptText: processing && index > count - 6 ? nil : transcriptCopy[index % transcriptCopy.count],
                audioArtifactId: index.isMultiple(of: 3) ? "mock://audio/\(index)" : nil,
                applicationName: app.0,
                bundleIdentifier: app.1
            )
        }
    }
}

public enum MockArtifactFactory {
    public static let loader: RecallImageLoader = { artifactID, quality in
        let index = Int(artifactID.split(separator: "/").last ?? "0") ?? 0
        return try renderFrame(index: index, quality: quality)
    }

    private static func renderFrame(index: Int, quality: RecallImageQuality) throws -> Data {
        let size = quality == .thumbnail ? NSSize(width: 320, height: 200) : NSSize(width: 1_280, height: 800)
        let image = NSImage(size: size)
        image.lockFocus()

        let palettes: [(NSColor, NSColor)] = [
            (.init(red: 0.18, green: 0.05, blue: 0.08, alpha: 1), .init(red: 0.94, green: 0.16, blue: 0.12, alpha: 1)),
            (.init(red: 0.04, green: 0.08, blue: 0.13, alpha: 1), .init(red: 0.16, green: 0.46, blue: 0.78, alpha: 1)),
            (.init(red: 0.07, green: 0.11, blue: 0.08, alpha: 1), .init(red: 0.32, green: 0.68, blue: 0.42, alpha: 1)),
            (.init(red: 0.12, green: 0.07, blue: 0.15, alpha: 1), .init(red: 0.65, green: 0.28, blue: 0.76, alpha: 1)),
        ]
        let palette = palettes[index % palettes.count]
        NSGradient(starting: palette.0, ending: NSColor.black)?.draw(in: NSRect(origin: .zero, size: size), angle: -24)

        let inset = size.width * 0.055
        let panel = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2), xRadius: 18, yRadius: 18)
        NSColor.white.withAlphaComponent(0.075).setFill()
        panel.fill()

        let title = "Moment \(String(format: "%02d", index + 1))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.width * 0.042, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        title.draw(at: NSPoint(x: inset * 1.7, y: size.height * 0.67), withAttributes: attributes)

        palette.1.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset * 1.7, y: size.height * 0.52, width: size.width * 0.24, height: max(5, size.height * 0.018)), xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.16).setFill()
        for row in 0..<3 {
            NSBezierPath(roundedRect: NSRect(x: inset * 1.7, y: size.height * (0.37 - Double(row) * 0.075), width: size.width * (0.52 - Double(row) * 0.08), height: max(4, size.height * 0.013)), xRadius: 3, yRadius: 3).fill()
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}
