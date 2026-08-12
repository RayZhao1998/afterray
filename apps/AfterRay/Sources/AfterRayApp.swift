import AfterRayRecall
import AppKit
import SwiftUI

@main
struct AfterRayApp: App {
    @NSApplicationDelegateAdaptor(AfterRayAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("AfterRay", id: "recall") {
            AfterRayRootView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_180, height: 760)
    }
}

@MainActor
private final class AfterRayAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_: Notification) {
        DaemonSupervisor.shared.stop()
    }
}

@MainActor
private final class AutomaticFullscreenController {
    static let shared = AutomaticFullscreenController()

    private weak var window: NSWindow?
    private var windowWaiters: [CheckedContinuation<NSWindow, Never>] = []
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var entryObserver: NSObjectProtocol?
    private var didRequestEntry = false

    func register(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false

        let waiters = windowWaiters
        windowWaiters.removeAll()
        waiters.forEach { $0.resume(returning: window) }
    }

    func enterOnce() async {
        let window = await resolveWindow()
        guard !didRequestEntry else { return }
        didRequestEntry = true
        guard !window.styleMask.contains(.fullScreen) else { return }

        await withCheckedContinuation { continuation in
            entryContinuation = continuation
            entryObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishEntry() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.finishEntry()
            }
            window.toggleFullScreen(nil)
        }
    }

    private func resolveWindow() async -> NSWindow {
        if let window { return window }
        return await withCheckedContinuation { continuation in
            windowWaiters.append(continuation)
        }
    }

    private func finishEntry() {
        if let entryObserver {
            NotificationCenter.default.removeObserver(entryObserver)
            self.entryObserver = nil
        }
        entryContinuation?.resume()
        entryContinuation = nil
    }
}

private struct AutomaticFullscreenProbe: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        registerWindow(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        registerWindow(from: nsView)
    }

    private func registerWindow(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            AutomaticFullscreenController.shared.register(window: window)
        }
    }
}

private struct AfterRayRootView: View {
    @StateObject private var store: RecallStore
    @StateObject private var control: AfterRayControlModel
    @StateObject private var audioPlayer: ArtifactAudioPlayer
    @StateObject private var permissions = SystemPermissionCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    private let images: RecallImageRepository

    init() {
        let daemon = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
        let repository = RecallImageRepository(daemon: daemon)
        _store = StateObject(wrappedValue: RecallStore(daemon: daemon))
        _control = StateObject(wrappedValue: AfterRayControlModel(daemon: daemon))
        _audioPlayer = StateObject(wrappedValue: ArtifactAudioPlayer(repository: repository))
        images = repository
    }

    var body: some View {
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
            artifactLoader: { artifactID in
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
        .background(Color(red: 0.025, green: 0.022, blue: 0.026))
        .background(AutomaticFullscreenProbe())
        .overlay(alignment: .top) {
            ImmersiveControlBar(
                model: control,
                onToggleRecording: toggleRecording,
                onSearch: { Task { await control.search() } }
            )
            .padding(.top, 22)
        }
        .overlay(alignment: .topTrailing) {
            if !control.searchHits.isEmpty {
                SearchResultsPanel(
                    hits: control.searchHits,
                    onSelect: openSearchHit,
                    onDismiss: control.dismissSearch
                )
                .frame(width: 390)
                .padding(.top, 74)
                .padding(.trailing, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
            }
        }
        .overlay {
            if !permissions.allGranted {
                PermissionPanel(coordinator: permissions)
                    .transition(.opacity)
            }
        }
        .task {
            await AutomaticFullscreenController.shared.enterOnce()
            await bootstrap()
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
        .animation(.easeOut(duration: 0.18), value: permissions.allGranted)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                permissions.refresh()
                if permissions.allGranted {
                    _ = await control.ensureRecording()
                    await store.loadLatestSession()
                }
            }
        }
    }

    private func bootstrap() async {
        do {
            try await DaemonSupervisor.shared.startIfNeeded()
        } catch {
            await control.refreshStatus()
            return
        }
        await permissions.requestRequiredPermissions()
        if permissions.allGranted {
            _ = await control.ensureRecording()
        } else {
            await control.refreshStatus()
        }
        await store.loadLatestSession()
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

private struct PermissionPanel: View {
    @ObservedObject var coordinator: SystemPermissionCoordinator

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("LET AFTERRAY REMEMBER")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(.red)
                    Text("Three local permissions are required")
                        .font(.title2.weight(.semibold))
                    Text("AfterRay starts recording automatically as soon as macOS grants all three. Nothing is uploaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 9) {
                    ForEach(RequiredPermission.allCases) { permission in
                        permissionRow(permission)
                    }
                }

                if coordinator.isRequesting {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for macOS approval…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Request permissions again") {
                        Task { await coordinator.requestRequiredPermissions() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(26)
            .frame(width: 470)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.6), radius: 36, y: 18)
        }
    }

    private func permissionRow(_ permission: RequiredPermission) -> some View {
        let granted = isGranted(permission)
        return HStack(spacing: 12) {
            Image(systemName: permission.icon)
                .frame(width: 22)
                .foregroundStyle(granted ? Color.green : Color.red)
            Text(permission.title)
                .font(.callout.weight(.medium))
            Spacer()
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Open Settings") { coordinator.openSettings(for: permission) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func isGranted(_ permission: RequiredPermission) -> Bool {
        switch permission {
        case .screenRecording: coordinator.screenRecording
        case .microphone: coordinator.microphone
        case .accessibility: coordinator.accessibility
        }
    }
}

private struct ImmersiveControlBar: View {
    @ObservedObject var model: AfterRayControlModel
    let onToggleRecording: () -> Void
    let onSearch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isRecording ? Color.red : Color.secondary.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .shadow(color: model.isRecording ? .red.opacity(0.8) : .clear, radius: 5)
                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Button(action: onToggleRecording) {
                Image(systemName: model.isRecording ? "pause.fill" : "record.circle")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.82))
            .disabled(!model.canToggleRecording)
            .help(model.isRecording ? "Pause capture" : "Resume capture")

            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: 1, height: 18)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
                TextField("Search your day", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
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
            .frame(width: 224)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(.ultraThinMaterial, in: Capsule())
        .background(.black.opacity(0.28), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.13), lineWidth: 1) }
        .shadow(color: .black.opacity(0.34), radius: 18, y: 6)
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
