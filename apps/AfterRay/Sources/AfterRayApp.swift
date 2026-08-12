import AfterRayRecall
import SwiftUI

@main
struct AfterRayApp: App {
    var body: some Scene {
        WindowGroup {
            AfterRayRootView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_180, height: 760)
    }
}

private struct AfterRayRootView: View {
    @StateObject private var store: RecallStore
    @StateObject private var control: AfterRayControlModel
    @StateObject private var audioPlayer: ArtifactAudioPlayer
    private let images: RecallImageRepository

    init() {
        let daemon = UnixSocketDaemonClient()
        let repository = RecallImageRepository(daemon: daemon)
        _store = StateObject(wrappedValue: RecallStore(daemon: daemon))
        _control = StateObject(wrappedValue: AfterRayControlModel(daemon: daemon))
        _audioPlayer = StateObject(wrappedValue: ArtifactAudioPlayer(repository: repository))
        images = repository
    }

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(
                model: control,
                onToggleRecording: toggleRecording,
                onSearch: { Task { await control.search() } }
            )

            RecallView(
                moments: store.moments,
                selectedIndex: Binding(
                    get: { store.selectedIndex },
                    set: { store.select(index: $0) }
                ),
                loadState: store.loadState,
                imageLoader: { artifactID, _ in
                    try await images.data(artifactID: artifactID)
                },
                onToggleFavorite: {
                    Task { await store.toggleFavorite() }
                },
                onToggleAudio: { moment in
                    Task { await audioPlayer.toggle(moment: moment) }
                },
                onReload: reload
            )
        }
        .background(Color(red: 0.025, green: 0.022, blue: 0.026))
        .overlay(alignment: .topTrailing) {
            if !control.searchHits.isEmpty {
                SearchResultsPanel(
                    hits: control.searchHits,
                    onSelect: openSearchHit,
                    onDismiss: control.dismissSearch
                )
                .frame(width: 390)
                .padding(.top, 56)
                .padding(.trailing, 18)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
            }
        }
        .task {
            async let status: Void = control.refreshStatus()
            async let timeline: Void = store.loadLatestSession()
            _ = await (status, timeline)
        }
        .task(id: control.status?.recordingState) {
            while !Task.isCancelled, control.isRecording {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await store.loadLatestSession()
                await control.refreshStatus()
            }
        }
        .animation(.easeOut(duration: 0.14), value: control.searchHits.isEmpty)
    }

    private func toggleRecording() {
        Task {
            let changed = await control.toggleRecording()
            if changed { await store.loadLatestSession() }
        }
    }

    private func reload() {
        Task {
            async let status: Void = control.refreshStatus()
            async let timeline: Void = store.loadLatestSession()
            _ = await (status, timeline)
        }
    }

    private func openSearchHit(_ hit: RecallSearchHit) {
        control.dismissSearch()
        Task { await store.openSearchHit(hit) }
    }
}

private struct ControlBar: View {
    @ObservedObject var model: AfterRayControlModel
    let onToggleRecording: () -> Void
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.secondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                    .shadow(color: model.isRecording ? .red.opacity(0.8) : .clear, radius: 5)
                Text(statusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Button(action: onToggleRecording) {
                Label(
                    model.isRecording ? "Stop" : "Record",
                    systemImage: model.isRecording ? "stop.fill" : "record.circle"
                )
            }
            .buttonStyle(RecordingButtonStyle(isRecording: model.isRecording))
            .disabled(!model.canToggleRecording)

            Spacer(minLength: 20)

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 280, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search OCR and transcript", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit(onSearch)
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.searchQuery.isEmpty {
                    Button(action: model.dismissSearch) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 290, height: 32)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(.black.opacity(0.82))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private var statusLabel: String {
        guard let status = model.status else { return "Daemon offline" }
        switch status.recordingState {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .stopping: return "Stopping"
        case .failed: return "Capture failed"
        }
    }
}

private struct SearchResultsPanel: View {
    let hits: [RecallSearchHit]
    let onSelect: (RecallSearchHit) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SEARCH RESULTS")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(hits) { hit in
                        Button { onSelect(hit) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Label(hit.source.uppercased(), systemImage: sourceIcon(hit.source))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.red)
                                    Spacer()
                                    Text(formatTimestamp(hit.capturedAtMs))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(hit.text)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(SearchResultButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 390)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private func sourceIcon(_ source: String) -> String {
        source.lowercased().contains("transcript") ? "waveform" : "text.viewfinder"
    }

    private func formatTimestamp(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct RecordingButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(.white)
            .background(isRecording ? Color.red.opacity(0.72) : Color.white.opacity(0.09), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct SearchResultButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
