import AppKit
import ImageIO
import QuartzCore
import SwiftUI

public typealias RecallImageLoader = (String) async throws -> Data
public typealias RecallArtifactLoader = (String) async throws -> Data

public struct RecallView: View {
    public let moments: [RecallMoment]
    @Binding public var selectedIndex: Int
    @Binding public var isLive: Bool
    public let loadState: RecallLoadState
    public var tuning: RecallVisualTuning
    public let imageLoader: RecallImageLoader
    public var artifactLoader: RecallArtifactLoader?
    public var onToggleFavorite: (() -> Void)?
    public var onToggleAudio: ((RecallMoment) -> Void)?
    public var onReload: (() -> Void)?

    @State private var dragOriginPosition: Int?
    @State private var scrollAccumulator: CGFloat = 0
    @State private var movementDirection = -1
    @State private var showsDetails = false

    public init(
        moments: [RecallMoment],
        selectedIndex: Binding<Int>,
        isLive: Binding<Bool> = .constant(false),
        loadState: RecallLoadState = .ready,
        tuning: RecallVisualTuning = .standard,
        imageLoader: @escaping RecallImageLoader,
        artifactLoader: RecallArtifactLoader? = nil,
        onToggleFavorite: (() -> Void)? = nil,
        onToggleAudio: ((RecallMoment) -> Void)? = nil,
        onReload: (() -> Void)? = nil
    ) {
        self.moments = moments
        self._selectedIndex = selectedIndex
        self._isLive = isLive
        self.loadState = loadState
        self.tuning = tuning
        self.imageLoader = imageLoader
        self.artifactLoader = artifactLoader
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
            if !isLive {
                RecallPalette.background.ignoresSafeArea()
            }

            switch loadState {
            case .loading:
                loadingView
            case .failed(let message):
                FailureView(message: message, onReload: onReload)
            case .ready, .processing:
                if moments.isEmpty {
                    EmptyRecallView(isProcessing: isProcessing)
                        .padding(40)
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

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Opening your memory…")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
    }

    private var recallContent: some View {
        ZStack {
            if !isLive, let moment = selectedMoment {
                ImmersiveArtifactImage(
                    artifactID: moment.imageArtifactId,
                    loader: imageLoader
                )
            }

            if !isLive {
                chromeGradients
            }

            VStack(spacing: 0) {
                if !isLive {
                    momentHeader
                        .padding(.horizontal, 26)
                        .padding(.top, 22)
                }

                Spacer(minLength: 100)

                AppUsageTimeline(
                    moments: moments,
                    selectedIndex: selectedIndex,
                    isLive: isLive,
                    tuning: tuning,
                    onSelect: { selectTimeline(position: $0) }
                )
                .padding(.horizontal, 26)
                .padding(.bottom, 18)
            }

            if showsDetails, !isLive {
                detailsPanel
                    .frame(width: 340)
                    .padding(.top, 76)
                    .padding(.trailing, 24)
                    .padding(.bottom, 154)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            ScrollWheelMonitor(onScroll: handleScroll)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(recallDrag)
        .onMoveCommand(perform: handleMoveCommand)
        .animation(.easeOut(duration: 0.18), value: showsDetails)
        .task(id: "\(selectedIndex):\(movementDirection)") {
            prefetchAroundSelection()
        }
    }

    private var chromeGradients: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(tuning.topScrimOpacity), .clear],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.23)
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.52),
                    .init(color: .black.opacity(0.35), location: 0.72),
                    .init(color: .black.opacity(tuning.bottomScrimOpacity), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [.black.opacity(0.34), .clear, .black.opacity(0.22)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var momentHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIdentity(moment: selectedMoment)

            Spacer(minLength: 24)

            if isProcessing {
                Label("Understanding", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(.black.opacity(0.34), in: Capsule())
            }

            chromeButton(
                symbol: selectedMoment?.isFavorite == true ? "star.fill" : "star",
                help: selectedMoment?.isFavorite == true ? "Remove favorite" : "Keep this moment",
                tint: selectedMoment?.isFavorite == true ? RecallPalette.ray : .white,
                action: { onToggleFavorite?() }
            )
            .disabled(selectedMoment == nil || onToggleFavorite == nil)

            chromeButton(
                symbol: showsDetails ? "sidebar.right" : "info.circle",
                help: showsDetails ? "Hide captured context" : "Show captured context",
                tint: .white,
                action: { showsDetails.toggle() }
            )
        }
    }

    private func chromeButton(
        symbol: String,
        help: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.36), in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.13), lineWidth: 1) }
        }
        .buttonStyle(RecallPressButtonStyle())
        .help(help)
    }

    private var detailsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("CAPTURED CONTEXT")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { showsDetails = false } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                EvidenceBlock(
                    eyebrow: "ON SCREEN",
                    icon: "text.viewfinder",
                    text: selectedMoment?.ocrText,
                    emptyText: isProcessing ? "OCR is processing…" : "No screen text found"
                )

                if
                    let artifactID = selectedMoment?.accessibilityArtifactId,
                    let artifactLoader
                {
                    AccessibilitySnapshotBlock(artifactID: artifactID, loader: artifactLoader)
                }

                EvidenceBlock(
                    eyebrow: "HEARD",
                    icon: "waveform",
                    text: selectedMoment?.transcriptText,
                    emptyText: isProcessing ? "Transcript is processing…" : "No transcript near this moment"
                )

                if let moment = selectedMoment, moment.audioArtifactId != nil {
                    Button { onToggleAudio?(moment) } label: {
                        Label("Play from this moment", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RecallCapsuleButtonStyle())
                    .disabled(onToggleAudio == nil)
                }
            }
            .padding(20)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 28, y: 12)
    }

    private var recallDrag: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragOriginPosition == nil {
                    dragOriginPosition = isLive ? moments.count : selectedIndex
                }
                guard let origin = dragOriginPosition else { return }
                let position = RecallGeometry.timelinePosition(
                    fromDragTranslation: value.translation.width,
                    originPosition: origin,
                    momentCount: moments.count,
                    pointsPerMoment: tuning.dragPointsPerMoment
                )
                selectTimeline(position: position)
            }
            .onEnded { _ in dragOriginPosition = nil }
    }

    private func handleScroll(delta: CGFloat, isPrecise: Bool, ended: Bool) {
        if ended {
            scrollAccumulator = 0
            return
        }
        guard delta != 0 else { return }
        if isLive, let step = RecallGeometry.liveScrollStep(delta: delta) {
            moveSelection(by: step)
            scrollAccumulator = 0
            return
        }
        if !isPrecise {
            moveSelection(by: delta > 0 ? -1 : 1)
            return
        }

        scrollAccumulator += delta
        let threshold: CGFloat = 10
        let steps = Int(abs(scrollAccumulator) / threshold)
        guard steps > 0 else { return }
        moveSelection(by: scrollAccumulator > 0 ? -steps : steps)
        scrollAccumulator.formTruncatingRemainder(dividingBy: threshold)
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: moveSelection(by: -1)
        case .right: moveSelection(by: 1)
        default: break
        }
    }

    private func moveSelection(by delta: Int) {
        guard !moments.isEmpty else { return }
        let currentPosition = isLive ? moments.count : selectedIndex
        let nextPosition = min(max(currentPosition + delta, 0), moments.count)
        selectTimeline(position: nextPosition)
    }

    private func selectTimeline(position: Int) {
        guard !moments.isEmpty else { return }
        let currentPosition = isLive ? moments.count : selectedIndex
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if position != currentPosition {
                movementDirection = position > currentPosition ? 1 : -1
            }
            if position == moments.count {
                selectedIndex = moments.count - 1
                isLive = true
            } else {
                selectedIndex = position
                isLive = false
            }
        }
    }

    private func prefetchAroundSelection() {
        guard !moments.isEmpty else { return }
        let center = min(max(selectedIndex, 0), moments.count - 1)
        var offsets = [0]
        for distance in 1...20 {
            offsets.append(distance * movementDirection)
            offsets.append(-distance * movementDirection)
        }
        let artifactIDs = offsets.compactMap { offset -> String? in
            let index = center + offset
            return moments.indices.contains(index) ? moments[index].imageArtifactId : nil
        }
        RecallDecodedImageCache.shared.prefetch(
            artifactIDs: artifactIDs,
            loader: imageLoader
        )
    }
}

private struct ImmersiveArtifactImage: View {
    let artifactID: String
    let loader: RecallImageLoader
    @State private var image: NSImage?

    var body: some View {
        let cachedImage = RecallDecodedImageCache.shared.cached(artifactID: artifactID)
        GeometryReader { geometry in
            ZStack {
                if let image = cachedImage ?? image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .shadow(color: .black.opacity(0.28), radius: 32)
                } else {
                    Rectangle().fill(RecallPalette.background)
                    ProgressView().controlSize(.small).tint(.white.opacity(0.65))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: artifactID) {
            if let cached = RecallDecodedImageCache.shared.cached(artifactID: artifactID) {
                image = cached
                return
            }
            guard let loaded = await RecallDecodedImageCache.shared.image(
                artifactID: artifactID,
                loader: loader
            ), !Task.isCancelled else { return }
            image = loaded
        }
    }
}

@MainActor
private final class RecallDecodedImageCache {
    static let shared = RecallDecodedImageCache()

    private let images = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var pendingPrefetches: [PrefetchRequest] = []
    private var activePrefetches = 0
    private let maximumConcurrentPrefetches = 6
    private var generation: UInt64 = 0

    private init() {
        images.countLimit = 48
        images.totalCostLimit = 1_536 * 1_024 * 1_024
    }

    func cached(artifactID: String) -> NSImage? {
        images.object(forKey: artifactID as NSString)
    }

    func image(
        artifactID: String,
        loader: @escaping RecallImageLoader
    ) async -> NSImage? {
        if let cached = cached(artifactID: artifactID) { return cached }
        if let existing = inFlight[artifactID] { return await existing.value }

        let requestGeneration = generation
        let task = Task { @MainActor () -> NSImage? in
            guard let data = try? await loader(artifactID) else { return nil }
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decode(data: data)
            }.value
            guard let decoded else { return nil }
            return NSImage(cgImage: decoded, size: .zero)
        }
        inFlight[artifactID] = task
        let decoded = await task.value
        inFlight[artifactID] = nil
        guard generation == requestGeneration else { return decoded }
        if let decoded {
            images.setObject(decoded, forKey: artifactID as NSString, cost: estimatedCost(decoded))
        }
        return decoded
    }


    func clearSensitiveData() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        pendingPrefetches.removeAll()
        images.removeAllObjects()
    }

    func prefetch(
        artifactIDs: [String],
        loader: @escaping RecallImageLoader
    ) {
        pendingPrefetches = artifactIDs.compactMap { artifactID in
            guard
                cached(artifactID: artifactID) == nil,
                inFlight[artifactID] == nil
            else { return nil }
            return PrefetchRequest(artifactID: artifactID, loader: loader)
        }
        pumpPrefetches()
    }

    private func pumpPrefetches() {
        while activePrefetches < maximumConcurrentPrefetches, !pendingPrefetches.isEmpty {
            let request = pendingPrefetches.removeFirst()
            guard
                cached(artifactID: request.artifactID) == nil,
                inFlight[request.artifactID] == nil
            else { continue }
            activePrefetches += 1
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await image(
                    artifactID: request.artifactID,
                    loader: request.loader
                )
                activePrefetches -= 1
                pumpPrefetches()
            }
        }
    }

    nonisolated private static func decode(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    private func estimatedCost(_ image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 1 }
        return max(representation.pixelsWide * representation.pixelsHigh * 4, 1)
    }

    private struct PrefetchRequest {
        let artifactID: String
        let loader: RecallImageLoader
    }
}

@MainActor
public func clearRecallDecodedImageCache() {
    RecallDecodedImageCache.shared.clearSensitiveData()
}

private struct AppIdentity: View {
    let moment: RecallMoment?

    var body: some View {
        HStack(spacing: 11) {
            ApplicationIcon(bundleIdentifier: moment?.bundleIdentifier, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(moment?.applicationName ?? "Unknown app")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text("AFTER RAY")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(RecallPalette.ray)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: 44)
        .background(.black.opacity(0.38), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
    }
}

private struct AppUsageTimeline: View {
    let moments: [RecallMoment]
    let selectedIndex: Int
    let isLive: Bool
    let tuning: RecallVisualTuning
    let onSelect: (Int) -> Void
    @State private var model: TimelineModel

    init(
        moments: [RecallMoment],
        selectedIndex: Int,
        isLive: Bool,
        tuning: RecallVisualTuning,
        onSelect: @escaping (Int) -> Void
    ) {
        self.moments = moments
        self.selectedIndex = selectedIndex
        self.isLive = isLive
        self.tuning = tuning
        self.onSelect = onSelect
        _model = State(initialValue: TimelineModel(moments: moments))
    }

    var body: some View {
        VStack(spacing: 9) {
            timestamp
            GeometryReader { geometry in
                let width = geometry.size.width
                let contentWidth = model.contentWidth(for: width, density: tuning.timelineDensity)
                let selectedX = model.x(forMomentAt: selectedIndex, width: contentWidth)

                ZStack(alignment: .leading) {
                    timelineTrack(width: contentWidth)
                        .offset(x: width / 2 - selectedX)

                    edgeFade

                    Rectangle()
                        .fill(RecallPalette.ray)
                        .frame(width: 2, height: tuning.timelineSegmentHeight + 10)
                        .position(x: width / 2, y: (tuning.timelineSegmentHeight + 20) / 2)
                        .shadow(color: RecallPalette.ray.opacity(0.9), radius: 7)
                }
                .clipped()
            }
            .frame(height: tuning.timelineSegmentHeight + 20)

            HStack(spacing: 7) {
                Image(systemName: "arrow.left.and.right")
                Text("Swipe or scroll to travel · Esc to close · ⌘⇧Space to return")
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
        }
        .onChange(of: momentsRevision) {
            model = TimelineModel(moments: moments)
        }
    }

    private var momentsRevision: String {
        "\(moments.count):\(moments.first?.id ?? "-"):\(moments.last?.id ?? "-")"
    }

    private var timestamp: some View {
        VStack(spacing: 2) {
            Text(isLive ? "NOW" : selectedDate.formatted(date: .omitted, time: .standard))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(
                isLive
                    ? "Swipe right to enter history"
                    : selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            )
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.black.opacity(0.46), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 1) }
        .overlay(alignment: .bottom) {
            Circle()
                .fill(RecallPalette.ray)
                .frame(width: 5, height: 5)
                .offset(y: 11)
                .shadow(color: RecallPalette.ray, radius: 6)
        }
    }

    private var selectedDate: Date {
        guard moments.indices.contains(selectedIndex) else { return .now }
        return Date(timeIntervalSince1970: TimeInterval(moments[selectedIndex].capturedAtMs) / 1_000)
    }

    private func timelineTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: tuning.timelineSegmentGap) {
                ForEach(model.runs) { run in
                    let runWidth = model.width(
                        for: run,
                        contentWidth: width,
                        segmentGap: tuning.timelineSegmentGap
                    )
                    Button { onSelect(run.centerIndex) } label: {
                        AppUsageSegmentView(
                            run: run,
                            width: runWidth,
                            height: tuning.timelineSegmentHeight
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(width: runWidth)
                    .help("\(run.applicationName) · \(run.durationLabel)")
                }
            }
            .frame(width: width, alignment: .leading)

            ForEach(Array(moments.enumerated()).filter(\.element.isFavorite), id: \.element.id) { index, _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .position(x: model.x(forMomentAt: index, width: width), y: 2)
            }
        }
        .frame(width: width, height: 56)
        .padding(.vertical, 6)
    }

    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 42)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 42)
        }
        .allowsHitTesting(false)
    }
}

private struct AppUsageSegmentView: View {
    let run: AppUsageRun
    let width: CGFloat
    let height: Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [run.color.opacity(0.92), run.color.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }

            if width >= 42 {
                HStack(spacing: 7) {
                    ApplicationIcon(bundleIdentifier: run.bundleIdentifier, size: 22)
                    if width >= 92 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.applicationName)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            Text(run.durationLabel)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.66))
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
    }
}

private struct ApplicationIcon: View {
    let bundleIdentifier: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var icon: NSImage? {
        guard
            let bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct AppUsageRun: Identifiable {
    let id: Int
    let applicationName: String
    let bundleIdentifier: String?
    let startMs: Int64
    let endMs: Int64
    let startIndex: Int
    let endIndex: Int
    let color: Color

    var centerIndex: Int { startIndex + (endIndex - startIndex) / 2 }
    var durationMs: Int64 { max(endMs - startMs, 1_000) }
    var durationLabel: String { DurationFormatter.short(milliseconds: durationMs) }
}

private struct TimelineModel {
    let moments: [RecallMoment]
    let runs: [AppUsageRun]
    let startMs: Int64
    let endMs: Int64

    init(moments: [RecallMoment]) {
        self.moments = moments
        guard let first = moments.first, let last = moments.last else {
            runs = []
            startMs = 0
            endMs = 1
            return
        }

        let intervals = zip(moments, moments.dropFirst())
            .map { max($1.capturedAtMs - $0.capturedAtMs, 1_000) }
            .sorted()
        let trailingInterval = intervals.isEmpty ? 10_000 : intervals[intervals.count / 2]
        startMs = first.capturedAtMs
        endMs = last.capturedAtMs + min(trailingInterval, 60_000)

        var collected: [AppUsageRun] = []
        var runStart = 0
        for index in 1...moments.count {
            let endsRun = index == moments.count || Self.identity(of: moments[index]) != Self.identity(of: moments[runStart])
            guard endsRun else { continue }
            let runEndMs = index < moments.count ? moments[index].capturedAtMs : endMs
            let identity = Self.identity(of: moments[runStart])
            collected.append(
                AppUsageRun(
                    id: collected.count,
                    applicationName: identity.name,
                    bundleIdentifier: identity.bundle,
                    startMs: moments[runStart].capturedAtMs,
                    endMs: runEndMs,
                    startIndex: runStart,
                    endIndex: index - 1,
                    color: RecallPalette.appColor(seed: identity.bundle ?? identity.name)
                )
            )
            runStart = index
        }
        runs = collected
    }

    func contentWidth(for viewportWidth: CGFloat, density: Double) -> CGFloat {
        let seconds = CGFloat(max(endMs - startMs, 1)) / 1_000
        return max(viewportWidth * 1.18, min(seconds * density, 9_000))
    }

    func width(for run: AppUsageRun, contentWidth: CGFloat, segmentGap: Double) -> CGFloat {
        let fraction = CGFloat(run.durationMs) / CGFloat(max(endMs - startMs, 1))
        return max(contentWidth * fraction - segmentGap, 5)
    }

    func x(forMomentAt index: Int, width: CGFloat) -> CGFloat {
        guard moments.indices.contains(index) else { return 0 }
        let elapsed = moments[index].capturedAtMs - startMs
        return width * CGFloat(elapsed) / CGFloat(max(endMs - startMs, 1))
    }

    private static func identity(of moment: RecallMoment) -> (name: String, bundle: String?) {
        (moment.applicationName ?? "Unknown app", moment.bundleIdentifier)
    }
}

private enum DurationFormatter {
    static func short(milliseconds: Int64) -> String {
        let totalMinutes = max(Int((Double(milliseconds) / 60_000).rounded()), 1)
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}

private struct ScrollWheelMonitor: NSViewRepresentable {
    let onScroll: (_ delta: CGFloat, _ isPrecise: Bool, _ ended: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.hostView = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var onScroll: (_ delta: CGFloat, _ isPrecise: Bool, _ ended: Bool) -> Void
        private var monitor: Any?
        private var displayLink: CADisplayLink?
        private var pendingDelta: CGFloat = 0
        private var pendingIsPrecise = true
        private var pendingEnd = false
        private var isScrolling = false
        private var lastEventTime: CFTimeInterval = 0

        init(onScroll: @escaping (_ delta: CGFloat, _ isPrecise: Bool, _ ended: Bool) -> Void) {
            self.onScroll = onScroll
        }

        func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.hostView?.window else { return event }
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                pendingDelta = RecallGeometry.accumulatedScrollDelta(
                    current: pendingDelta,
                    incoming: delta
                )
                pendingIsPrecise = event.hasPreciseScrollingDeltas
                pendingEnd = event.phase == .ended || event.momentumPhase == .ended
                lastEventTime = CACurrentMediaTime()
                isScrolling = true
                return event
            }
            guard let hostView else { return }
            let displayLink = hostView.displayLink(
                target: self,
                selector: #selector(displayLinkDidFire(_:))
            )
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: 120
            )
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func displayLinkDidFire(_: CADisplayLink) {
            let drained = RecallGeometry.drainScrollDelta(pendingDelta)
            let delta = drained.emitted
            pendingDelta = drained.remaining
            if delta != 0 {
                onScroll(delta, pendingIsPrecise, false)
            }

            let drainedCompletely = abs(pendingDelta) < 0.001
            let wentIdle = isScrolling
                && drainedCompletely
                && CACurrentMediaTime() - lastEventTime >= 0.075
            if drainedCompletely, pendingEnd || wentIdle {
                pendingEnd = false
                isScrolling = false
                onScroll(0, pendingIsPrecise, true)
            }
        }
    }
}

private struct AccessibilitySnapshotBlock: View {
    let artifactID: String
    let loader: RecallArtifactLoader
    @State private var expanded = false
    @State private var snapshot = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(snapshot.isEmpty ? "Loading…" : snapshot)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
            .frame(maxHeight: 240)
        } label: {
            Label("ACCESSIBILITY TREE", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(RecallPalette.ray.opacity(0.9))
        }
        .task(id: expanded) {
            guard expanded, snapshot.isEmpty else { return }
            guard let data = try? await loader(artifactID) else {
                snapshot = "The snapshot could not be loaded."
                return
            }
            if
                let object = try? JSONSerialization.jsonObject(with: data),
                let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            {
                snapshot = String(decoding: pretty, as: UTF8.self)
            } else {
                snapshot = String(decoding: data, as: UTF8.self)
            }
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
                .font(.system(size: 13, weight: .regular, design: .rounded))
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
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(RecallPalette.ray)
            Text(isProcessing ? "The first moments are being prepared" : "Your day begins here")
                .font(.title2.weight(.medium))
            Text(isProcessing ? "Keep AfterRay running for a moment." : "AfterRay is capturing automatically. Your first screen will appear shortly.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 30, y: 14)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 28, y: 12)
    }
}

private struct RecallPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
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
    static let background = Color(red: 0.018, green: 0.016, blue: 0.020)
    static let ray = Color(red: 1.0, green: 0.20, blue: 0.14)

    static func appColor(seed: String) -> Color {
        let palette = [
            Color(red: 0.93, green: 0.20, blue: 0.14),
            Color(red: 0.86, green: 0.34, blue: 0.16),
            Color(red: 0.68, green: 0.23, blue: 0.42),
            Color(red: 0.38, green: 0.34, blue: 0.72),
            Color(red: 0.19, green: 0.46, blue: 0.58),
            Color(red: 0.26, green: 0.52, blue: 0.39),
        ]
        let hash = seed.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return palette[Int(UInt(bitPattern: hash) % UInt(palette.count))]
    }
}
