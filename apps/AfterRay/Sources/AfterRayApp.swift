import AfterRayRecall
import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct AfterRayApp: App {
    @NSApplicationDelegateAdaptor(AfterRayAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
private final class AfterRayAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        RecallOverlayController.shared.start()
    }

    func applicationWillTerminate(_: Notification) {
        RecallOverlayController.shared.stop()
        DaemonSupervisor.shared.stop()
    }
}

private final class RecallOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_: Any?) {
        RecallOverlayController.shared.hide(returnFocus: true)
    }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private let recallHotKeyHandler: EventHandlerUPP = { _, _, _ in
    DispatchQueue.main.async {
        RecallOverlayController.shared.toggle()
    }
    return noErr
}

@MainActor
private final class RecallOverlayController {
    static let shared = RecallOverlayController()

    private var panel: RecallOverlayPanel?
    private var previousApplication: NSRunningApplication?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var resignKeyObserver: NSObjectProtocol?

    func start() {
        guard panel == nil else { return }

        let panel = RecallOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: AfterRayRootView())
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        self.panel = panel
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            Task { @MainActor in
                RecallOverlayController.shared.hide(returnFocus: false)
            }
        }
        registerHotKey()
        show()
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func toggle() {
        if panel?.isVisible == true {
            hide(returnFocus: true)
        } else {
            show()
        }
    }

    func show() {
        guard let panel else { return }
        PermissionGuideController.shared.hide()
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }
        panel.setFrame(targetScreen.frame, display: true)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    func hide(returnFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        let application = returnFocus ? previousApplication : nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
            application?.activate(options: [])
        }
    }

    private var targetScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            recallHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard handlerStatus == noErr else { return }

        let identifier = EventHotKeyID(signature: 0x4152_5952, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }
}

@MainActor
private final class PermissionGuideController {
    static let shared = PermissionGuideController()

    private let panelSize = NSSize(width: 392, height: 214)
    private var panel: PermissionGuidePanel?

    func show(for permission: RequiredPermission) {
        let panel = panel ?? makePanel()
        let hostingView = NSHostingView(
            rootView: PermissionDropGuide(permission: permission)
                .frame(width: panelSize.width, height: panelSize.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = []
        panel.contentView = hostingView

        let screen = targetScreen
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - panelSize.width - 28,
            y: screen.visibleFrame.maxY - panelSize.height - 28
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.alphaValue = 0
        NSApp.unhideWithoutActivation()
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
    }

    func showAfterOpeningSettings(for permission: RequiredPermission) {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.show(for: permission)
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func makePanel() -> PermissionGuidePanel {
        let panel = PermissionGuidePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.minSize = panelSize
        panel.maxSize = panelSize
        panel.contentMinSize = panelSize
        panel.contentMaxSize = panelSize
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        self.panel = panel
        return panel
    }

    private var targetScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

private struct PermissionDropGuide: View {
    let permission: RequiredPermission

    private var applicationURL: URL { Bundle.main.bundleURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: permission.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(.red.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text("Add AfterRay to \(permission.title)")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Drag the application below into the list in System Settings, then turn it on.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("AfterRay")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Drag into System Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "hand.draw")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.red.opacity(0.48), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onDrag {
                NSItemProvider(contentsOf: applicationURL)
                    ?? NSItemProvider(object: applicationURL as NSURL)
            } preview: {
                HStack(spacing: 9) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                        .resizable()
                        .frame(width: 34, height: 34)
                    Text("AfterRay")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Text("After granting access, press ⌘⇧Space to return.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 392, height: 214, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
    }
}

private struct AfterRayRootView: View {
    @StateObject private var store: RecallStore
    @StateObject private var control: AfterRayControlModel
    @StateObject private var audioPlayer: ArtifactAudioPlayer
    @StateObject private var permissions = SystemPermissionCoordinator()
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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
        await permissions.requestInitialPermissionsOnce()
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

                Text("After changing a permission, press ⌘⇧Space to return to AfterRay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if coordinator.isRequesting {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for macOS approval…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Check permissions") { coordinator.refresh() }
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
                Button("Open Settings") {
                    RecallOverlayController.shared.hide(returnFocus: false)
                    PermissionGuideController.shared.showAfterOpeningSettings(for: permission)
                    coordinator.openSettings(for: permission)
                }
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
