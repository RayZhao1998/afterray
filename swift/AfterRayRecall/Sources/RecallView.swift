import AppKit
import SwiftUI

public enum RecallImageQuality: Sendable {
    case thumbnail
    case full
}

public typealias RecallImageLoader = (String, RecallImageQuality) async throws -> Data

public struct RecallView: View {
    public let moments: [RecallMoment]
    @Binding public var selectedIndex: Int
    public let loadState: RecallLoadState
    public var tuning: RecallVisualTuning
    public let imageLoader: RecallImageLoader
    public var onToggleFavorite: (() -> Void)?
    public var onToggleAudio: ((RecallMoment) -> Void)?
    public var onReload: (() -> Void)?

    @State private var dragOriginIndex: Int?

    public init(
        moments: [RecallMoment],
        selectedIndex: Binding<Int>,
        loadState: RecallLoadState = .ready,
        tuning: RecallVisualTuning = .standard,
        imageLoader: @escaping RecallImageLoader,
        onToggleFavorite: (() -> Void)? = nil,
        onToggleAudio: ((RecallMoment) -> Void)? = nil,
        onReload: (() -> Void)? = nil
    ) {
        self.moments = moments
        self._selectedIndex = selectedIndex
        self.loadState = loadState
        self.tuning = tuning
        self.imageLoader = imageLoader
        self.onToggleFavorite = onToggleFavorite
        self.onToggleAudio = onToggleAudio
        self.onReload = onReload
    }

    private var selectedMoment: RecallMoment? {
        guard moments.indices.contains(selectedIndex) else { return nil }
        return moments[selectedIndex]
    }

    public var body: some View {
        ZStack {
            RecallPalette.background.ignoresSafeArea()
            radialAtmosphere

            switch loadState {
            case .loading:
                ProgressView("Opening your memory…")
                    .controlSize(.large)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                FailureView(message: message, onReload: onReload)
            case .ready, .processing:
                if moments.isEmpty {
                    EmptyRecallView(isProcessing: isProcessing)
                } else {
                    recallContent
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var isProcessing: Bool {
        if case .processing = loadState { return true }
        return false
    }

    private var radialAtmosphere: some View {
        RadialGradient(
            colors: [RecallPalette.ray.opacity(tuning.glowStrength * 0.22), .clear],
            center: .init(x: 0.5, y: 0.42),
            startRadius: 20,
            endRadius: 520
        )
        .allowsHitTesting(false)
    }

    private var recallContent: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 18)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    hero
                    evidencePanel.frame(width: 300)
                }
                VStack(spacing: 20) {
                    hero
                    evidencePanel.frame(maxHeight: 210)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .frame(maxHeight: .infinity)

            timeline
                .padding(.top, 20)
                .padding(.bottom, 22)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(recallDrag)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AFTER RAY")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(RecallPalette.ray)
                Text(selectedMoment.map(formatTimestamp) ?? "No moment")
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }

            Spacer(minLength: 24)

            if isProcessing {
                Label("Understanding", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Button(action: { onToggleFavorite?() }) {
                Image(systemName: selectedMoment?.isFavorite == true ? "star.fill" : "star")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(selectedMoment?.isFavorite == true ? RecallPalette.ray : .white)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(RecallPressButtonStyle())
            .disabled(selectedMoment == nil || onToggleFavorite == nil)
            .help(selectedMoment?.isFavorite == true ? "Remove favorite" : "Keep this moment")
        }
    }

    private var hero: some View {
        Group {
            if let moment = selectedMoment {
                ArtifactImage(
                    artifactID: moment.imageArtifactId,
                    quality: .full,
                    loader: imageLoader
                )
                .id(moment.id)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: RecallPalette.ray.opacity(tuning.glowStrength * 0.34), radius: 36)
                .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
                .scaleEffect(tuning.selectedScale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.16), value: selectedIndex)
    }

    private var evidencePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                EvidenceBlock(
                    eyebrow: "ON SCREEN",
                    icon: "text.viewfinder",
                    text: selectedMoment?.ocrText,
                    emptyText: isProcessing ? "OCR is processing…" : "No screen text found"
                )

                EvidenceBlock(
                    eyebrow: "HEARD",
                    icon: "waveform",
                    text: selectedMoment?.transcriptText,
                    emptyText: isProcessing ? "Transcript is processing…" : "No transcript near this moment"
                )

                if let moment = selectedMoment, moment.audioArtifactId != nil {
                    Button {
                        onToggleAudio?(moment)
                    } label: {
                        Label("Play from this moment", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RecallCapsuleButtonStyle())
                    .disabled(onToggleAudio == nil)
                }
            }
            .padding(18)
        }
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var timeline: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: tuning.thumbnailSpacing) {
                        Color.clear.frame(width: 180)
                        ForEach(Array(moments.enumerated()), id: \.element.id) { index, moment in
                            TimelineThumbnail(
                                moment: moment,
                                distance: abs(selectedIndex - index),
                                width: tuning.thumbnailWidth,
                                neighborScale: tuning.neighborScale,
                                dimOpacity: tuning.dimOpacity,
                                loader: imageLoader
                            )
                            .id(moment.id)
                            .onTapGesture { selectedIndex = index }
                        }
                        Color.clear.frame(width: 180)
                    }
                    .padding(.vertical, 18)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    guard moments.indices.contains(newIndex) else { return }
                    withAnimation(.easeOut(duration: 0.14)) {
                        proxy.scrollTo(moments[newIndex].id, anchor: .center)
                    }
                }
                .onAppear {
                    guard moments.indices.contains(selectedIndex) else { return }
                    proxy.scrollTo(moments[selectedIndex].id, anchor: .center)
                }
            }

            VStack(spacing: 4) {
                Capsule()
                    .fill(RecallPalette.ray)
                    .frame(width: 2, height: 86)
                    .shadow(color: RecallPalette.ray, radius: 9)
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
            }
            .allowsHitTesting(false)
        }
        .frame(height: 126)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.34), .clear], startPoint: .leading, endPoint: .trailing)
        )
    }

    private var recallDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragOriginIndex == nil { dragOriginIndex = selectedIndex }
                guard let origin = dragOriginIndex else { return }
                if let index = RecallGeometry.index(
                    fromDragTranslation: value.translation.width,
                    originIndex: origin,
                    count: moments.count,
                    pointsPerMoment: tuning.dragPointsPerMoment
                ) {
                    selectedIndex = index
                }
            }
            .onEnded { _ in dragOriginIndex = nil }
    }

    private func formatTimestamp(_ moment: RecallMoment) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(moment.capturedAtMs) / 1_000)
        return date.formatted(date: .abbreviated, time: .standard)
    }
}

private struct TimelineThumbnail: View {
    let moment: RecallMoment
    let distance: Int
    let width: Double
    let neighborScale: Double
    let dimOpacity: Double
    let loader: RecallImageLoader

    var body: some View {
        ArtifactImage(artifactID: moment.imageArtifactId, quality: .thumbnail, loader: loader)
            .frame(width: width, height: width * 0.625)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if moment.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(RecallPalette.ray, in: Circle())
                        .padding(5)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(distance == 0 ? 0.32 : 0.10), lineWidth: 1)
            }
            .scaleEffect(distance == 0 ? 1 : max(neighborScale - Double(distance) * 0.035, 0.72))
            .opacity(distance == 0 ? 1 : max(1 - dimOpacity - Double(distance) * 0.08, 0.28))
            .animation(.easeOut(duration: 0.14), value: distance)
    }
}

private struct ArtifactImage: View {
    let artifactID: String
    let quality: RecallImageQuality
    let loader: RecallImageLoader

    @State private var data: Data?

    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.04))
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView().controlSize(.small).tint(.white.opacity(0.6))
            }
        }
        .clipped()
        .task(id: artifactID) {
            data = nil
            data = try? await loader(artifactID, quality)
        }
    }
}

private struct EvidenceBlock: View {
    let eyebrow: String
    let icon: String
    let text: String?
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(eyebrow, systemImage: icon)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(RecallPalette.ray.opacity(0.9))
            Text(text?.isEmpty == false ? text! : emptyText)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(text?.isEmpty == false ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmptyRecallView: View {
    let isProcessing: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: isProcessing ? "sparkles.rectangle.stack" : "rectangle.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(RecallPalette.ray)
            Text(isProcessing ? "The first moments are being prepared" : "Nothing to look back on yet")
                .font(.title3.weight(.medium))
            Text(isProcessing ? "Keep AfterRay running for a moment." : "Start a recording session from the CLI, then return here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

private struct FailureView: View {
    let message: String
    let onReload: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(RecallPalette.ray)
            Text("AfterRay daemon is unavailable").font(.title3.weight(.medium))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let onReload {
                Button("Try Again", action: onReload)
                    .buttonStyle(RecallCapsuleButtonStyle())
            }
        }
        .padding(40)
    }
}

private struct RecallPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct RecallCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(RecallPalette.ray.opacity(configuration.isPressed ? 0.68 : 0.86), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private enum RecallPalette {
    static let background = Color(red: 0.025, green: 0.022, blue: 0.026)
    static let ray = Color(red: 1.0, green: 0.22, blue: 0.16)
}
