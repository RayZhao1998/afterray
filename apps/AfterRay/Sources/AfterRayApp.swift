import AfterRayRecall
import AppKit
import Carbon.HIToolbox
import SwiftUI

private extension Notification.Name {
    static let afterRayRecallDidOpen = Notification.Name("dev.afterray.recall-did-open")
    static let afterRayRecallWillHide = Notification.Name("dev.afterray.recall-will-hide")
    static let afterRayRecallToggleAudio = Notification.Name("dev.afterray.recall-toggle-audio")
    static let afterRaySystemSessionWillSuspend = Notification.Name(
        "dev.afterray.system-session-will-suspend"
    )
    static let afterRaySystemSessionDidResume = Notification.Name(
        "dev.afterray.system-session-did-resume"
    )
}

@MainActor
private final class RecallOverlayLayout: ObservableObject {
    static let shared = RecallOverlayLayout()

    @Published private(set) var topSafeAreaInset: CGFloat = 0

    func update(for screen: NSScreen) {
        topSafeAreaInset = screen.safeAreaInsets.top
    }
}

@main
struct AfterRayApp: App {
    @NSApplicationDelegateAdaptor(AfterRayAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
private final class AfterRayAppDelegate: NSObject, NSApplicationDelegate {
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_: Notification) {
        AfterRayLog.install()
        AfterRayLog.info("application launched")
        installAppMenu()
        AfterRayMenuBar.shared.install()
        observeSystemSessionSecurityEvents()
        RecallOverlayController.shared.start()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            RecallOverlayController.shared.stop()
            await DaemonSupervisor.shared.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        workspaceObservers.forEach { observer in
            workspace.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        AfterRayMenuBar.shared.remove()
        RecallOverlayController.shared.stop()
        DaemonSupervisor.shared.stop()
    }

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit AfterRay",
            action: #selector(quitAfterRay),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        AfterRaySettingsController.shared.show()
    }

    @objc private func quitAfterRay() {
        NSApp.terminate(nil)
    }

    private func observeSystemSessionSecurityEvents() {
        let center = NSWorkspace.shared.notificationCenter
        let suspendNotifications: [(Notification.Name, String)] = [
            (NSWorkspace.sessionDidResignActiveNotification, "lock"),
            (NSWorkspace.screensDidSleepNotification, "sleep"),
            (NSWorkspace.willSleepNotification, "sleep"),
        ]
        let resumeNotifications: [Notification.Name] = [
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ]
        workspaceObservers += suspendNotifications.map { name, reason in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    await AfterRayAppDelegate.pauseCapture(reason: reason)
                }
            }
        }
        workspaceObservers += resumeNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    AfterRayAppDelegate.resumeCapture()
                }
            }
        }

        let distributed = DistributedNotificationCenter.default()
        workspaceObservers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    await AfterRayAppDelegate.pauseCapture(reason: "lock")
                }
            }
        )
        workspaceObservers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    AfterRayAppDelegate.resumeCapture()
                }
            }
        )
    }

    @MainActor
    fileprivate static func pauseCapture(reason: String) async {
        NotificationCenter.default.post(name: .afterRaySystemSessionWillSuspend, object: nil)
        DaemonSupervisor.shared.suspendForSystemLock()
        let client = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
        _ = try? await client.recordStop(reason: reason)
    }

    @MainActor
    fileprivate static func resumeCapture() {
        DaemonSupervisor.shared.resumeAfterSystemUnlock()
        NotificationCenter.default.post(name: .afterRaySystemSessionDidResume, object: nil)
    }
}

@MainActor
private final class AfterRayMenuBar: NSObject {
    static let shared = AfterRayMenuBar()

    private var statusItem: NSStatusItem?

    private override init() {
        super.init()
    }

    func install() {
        guard statusItem == nil else {
            refresh()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setButtonType(.momentaryPushIn)
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open AfterRay",
            action: #selector(openAfterRay),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit AfterRay",
            action: #selector(quitAfterRay),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        refresh()
        print(
            "AfterRay: menu extra installed visible=\(item.isVisible) button=\(item.button != nil)"
        )
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func setRecording(_: Bool) {}

    func setOverlayVisible(_: Bool) {}

    @objc private func openAfterRay() {
        RecallOverlayController.shared.show()
    }

    @objc private func openSettings() {
        AfterRaySettingsController.shared.show()
    }

    @objc private func quitAfterRay() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }
        statusItem?.isVisible = true
        button.image = Self.icon()
        button.toolTip = "AfterRay"
    }

    private static func icon() -> NSImage {
        let image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "AfterRay")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

/// Transparent overlay pixels must still own the mouse. Otherwise trackpad
/// scrolls over empty timeline chrome fall through to the app behind and
/// AfterRay never sees them.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) ?? self
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
final class RecallOverlayController {
    static let shared = RecallOverlayController()

    private var panel: RecallOverlayPanel?
    private var previousApplication: NSRunningApplication?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var resignKeyObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    func start() {
        guard panel == nil else { return }

        let panel = RecallOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = OverlayHostingView(rootView: AfterRayRootView())
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
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
            .ignoresCycle,
        ]
        self.panel = panel
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { _ in
            Task { @MainActor in
                if AfterRaySettingsController.shared.isPresented { return }
                RecallOverlayController.shared.hide(returnFocus: false)
            }
        }
        registerHotKey()
        installKeyMonitor()
        show()
    }

    var isVisible: Bool { panel?.isVisible == true }

    var currentScreen: NSScreen? {
        panel?.screen ?? targetScreen
    }

    func isOverlayWindow(_ window: NSWindow) -> Bool {
        panel === window
    }

    func makeKeyIfVisible() {
        guard let panel, panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    func stop() {
        NotificationCenter.default.post(name: .afterRayRecallWillHide, object: nil)
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        hotKey = nil
        eventHandler = nil
        keyMonitor = nil
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
        panel?.orderOut(nil)
        panel = nil
        AfterRayMenuBar.shared.setOverlayVisible(false)
    }

    func toggle() {
        if PermissionGuideController.shared.isVisible {
            PermissionGuideController.shared.hide()
            show()
            return
        }
        if panel?.isVisible == true {
            hide(returnFocus: true)
        } else {
            show()
        }
    }

    func show() {
        guard let panel else { return }
        PermissionGuideController.shared.hide()
        NotificationCenter.default.post(name: .afterRayRecallDidOpen, object: nil)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = NSWorkspace.shared.frontmostApplication
        }
        let screen = targetScreen
        RecallOverlayLayout.shared.update(for: screen)
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(panel)
        AfterRayMenuBar.shared.setOverlayVisible(true)
    }

    func hide(returnFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        NotificationCenter.default.post(name: .afterRayRecallWillHide, object: nil)
        let application = returnFocus ? previousApplication : nil
        panel.orderOut(nil)
        panel.alphaValue = 1
        AfterRayMenuBar.shared.setOverlayVisible(false)
        application?.activate(options: [])
    }

    private var targetScreen: NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if RecallOverlayController.shared.shouldConsumeCloseKey(event) {
                RecallOverlayController.shared.closeFromKeyboard()
                return nil
            }
            if RecallOverlayController.shared.shouldConsumeAudioToggleKey(event) {
                NotificationCenter.default.post(name: .afterRayRecallToggleAudio, object: nil)
                return nil
            }
            return event
        }
    }

    fileprivate func shouldConsumeCloseKey(_ event: NSEvent) -> Bool {
        if PermissionGuideController.shared.isVisible {
            return event.keyCode == 53
        }
        guard panel?.isVisible == true, panel?.isKeyWindow == true else { return false }
        if event.keyCode == 53 { return true }
        return event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers == "w"
    }

    fileprivate func shouldConsumeAudioToggleKey(_ event: NSEvent) -> Bool {
        guard panel?.isVisible == true, panel?.isKeyWindow == true else { return false }
        guard event.keyCode == 49 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return false }
        if panel?.firstResponder is NSTextView { return false }
        return true
    }

    fileprivate func closeFromKeyboard() {
        if AfterRaySettingsController.shared.isPresented {
            AfterRaySettingsController.shared.hide()
            return
        }
        if PermissionGuideController.shared.isVisible {
            PermissionGuideController.shared.hide()
            return
        }
        hide(returnFocus: true)
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
    private var permissionPollTask: Task<Void, Never>?

    var isVisible: Bool { panel?.isVisible == true }

    func show(for permission: RequiredPermission) {
        let panel = panel ?? makePanel()
        let hostingView = NSHostingView(
            rootView: PermissionDropGuide(
                permission: permission,
                onDismiss: { [weak self] in self?.hide() }
            )
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
        monitorPermission(permission)
    }

    func showAfterOpeningSettings(for permission: RequiredPermission) {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.show(for: permission)
        }
    }

    func hide() {
        permissionPollTask?.cancel()
        permissionPollTask = nil
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
        panel.canHide = true
        panel.becomesKeyOnlyIfNeeded = true
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

    private func monitorPermission(_ permission: RequiredPermission) {
        permissionPollTask?.cancel()
        permissionPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, self?.panel?.isVisible == true else { return }
                if permission.isGrantedNow {
                    self?.hide()
                    return
                }
            }
        }
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
    let onDismiss: () -> Void

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

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
                .help("Dismiss")
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
            .overlay {
                ApplicationBundleDragSource(applicationURL: applicationURL)
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

/// Uses AppKit's native file-URL pasteboard writer. System Settings' privacy
/// lists do not reliably accept SwiftUI content providers whose first declared
/// type is a dynamically generated bundle-content UTI.
private struct ApplicationBundleDragSource: NSViewRepresentable {
    let applicationURL: URL

    func makeNSView(context _: Context) -> ApplicationBundleDragSourceView {
        ApplicationBundleDragSourceView(applicationURL: applicationURL)
    }

    func updateNSView(_ view: ApplicationBundleDragSourceView, context _: Context) {
        view.applicationURL = applicationURL
    }
}

private final class ApplicationBundleDragSourceView: NSView, NSDraggingSource {
    var applicationURL: URL

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func mouseDragged(with event: NSEvent) {
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        icon.size = NSSize(width: 52, height: 52)
        let point = convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: point.x - 26,
            y: point.y - 26,
            width: 52,
            height: 52
        )
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(frame, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(
        _: NSDraggingSession,
        sourceOperationMaskFor _: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for _: NSDraggingSession) -> Bool { true }
}

private struct AfterRayRootView: View {
    @StateObject private var store: RecallStore
    @StateObject private var control: AfterRayControlModel
    @StateObject private var audioPlayer: ArtifactAudioPlayer
    @StateObject private var permissions = SystemPermissionCoordinator()
    @ObservedObject private var overlayLayout = RecallOverlayLayout.shared
    @ObservedObject private var settings = AfterRaySettingsController.shared
    @State private var isLive = true
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
            playheadMs: Binding(
                get: { store.playheadMs },
                set: { store.select(playheadMs: $0) }
            ),
            isLive: $isLive,
            loadState: store.loadState,
            imageLoader: { artifactID in
                try await images.data(artifactID: artifactID)
            },
            artifactLoader: { artifactID in
                try await images.data(artifactID: artifactID)
            },
            onToggleFavorite: {
                Task { await store.toggleFavorite() }
            },
            onToggleAudio: { moment in
                audioPlayer.toggle(moment: moment)
            },
            isAudioPlaying: audioPlayer.isPlaying,
            isAudioBuffering: audioPlayer.isBuffering,
            playingAudioArtifactID: audioPlayer.playingArtifactID,
            onReload: reload,
            onOpenSettings: { AfterRaySettingsController.shared.show() },
            chromeTopPadding: controlBarTopPadding
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(permissions.allGranted ? 1 : 0)
        .background(
            isLive || !permissions.allGranted
                ? Color.clear
                : Color(red: 0.025, green: 0.022, blue: 0.026)
        )
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                ImmersiveControlBar(
                    model: control,
                    onToggleRecording: toggleRecording,
                    onSearch: { Task { await control.search() } },
                    onClose: { RecallOverlayController.shared.hide(returnFocus: true) }
                )
                ImmersiveAskBar(
                    model: control,
                    onAsk: submitAsk,
                    onOpenSettings: { AfterRaySettingsController.shared.show() },
                    onSelectCitation: openAskCitation
                )
                if let message = control.message, !control.isRecording {
                    CaptureFailureBanner(message: message, onRetry: toggleRecording)
                }
            }
            .padding(.top, controlBarTopPadding)
        }
        .overlay(alignment: .topTrailing) {
            if isLive {
                OverlaySettingsButton(action: { AfterRaySettingsController.shared.show() })
                    .padding(.top, controlBarTopPadding)
                    .padding(.trailing, RecallGeometry.overlayChromeMargin)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !control.searchHits.isEmpty {
                SearchResultsPanel(
                    hits: control.searchHits,
                    onSelect: openSearchHit,
                    onDismiss: control.dismissSearch
                )
                .frame(width: 390)
                .padding(.top, RecallGeometry.detailsMenuTopPadding(chromeTopPadding: controlBarTopPadding))
                .padding(.trailing, RecallGeometry.overlayChromeMargin)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
            }
        }
        .overlay {
            if !permissions.allGranted {
                PermissionPanel(coordinator: permissions)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        .overlay {
            if settings.isPresented {
                AfterRaySettingsOverlay(
                    model: settings.model,
                    onClose: { settings.hide() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: settings.isPresented)
        .onExitCommand {
            audioPlayer.stop()
            RecallOverlayController.shared.hide(returnFocus: true)
        }
        .onChange(of: isLive) { _, live in
            if live { audioPlayer.stop() }
        }
        .onChange(of: control.isRecording, initial: true) { _, isRecording in
            AfterRayMenuBar.shared.setRecording(isRecording)
        }
        .task(id: audioPrefetchKey) {
            audioPlayer.prefetch(artifactID: audioPrefetchKey.isEmpty ? nil : audioPrefetchKey)
        }
        .task {
            await bootstrap()
        }
        .task {
            await keepDaemonAlive()
        }
        .task(id: control.status?.recordingState) {
            while !Task.isCancelled, control.isRecording {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await store.refreshTimeline(preservingSelection: !isLive)
                await control.refreshStatus()
            }
        }
        .animation(.easeOut(duration: 0.14), value: control.searchHits.isEmpty)
        .animation(.easeOut(duration: 0.14), value: control.isAsking)
        .animation(.easeOut(duration: 0.14), value: control.askAnswer == nil)
        .animation(.easeOut(duration: 0.18), value: permissions.allGranted)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                guard await startDaemonOrReportFailure() != nil else { return }
                permissions.refresh()
                if permissions.allGranted {
                    _ = await control.ensureRecording()
                    await store.refreshTimeline(preservingSelection: !isLive)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallDidOpen)) { _ in
            audioPlayer.stop()
            isLive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallWillHide)) { _ in
            audioPlayer.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRayRecallToggleAudio)) { _ in
            guard !isLive, let moment = store.selectedMoment, moment.hasVisibleTranscript, moment.audioArtifactId != nil else { return }
            audioPlayer.toggle(moment: moment)
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRaySystemSessionDidResume)) { _ in
            Task {
                guard await startDaemonOrReportFailure() != nil else { return }
                permissions.refresh()
                if permissions.allGranted, !DaemonSupervisor.shared.isCapturePausedForSystemLock {
                    _ = await control.ensureRecording()
                }
                await store.refreshTimeline(preservingSelection: !isLive)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .afterRaySystemSessionWillSuspend)) { _ in
            audioPlayer.stop()
            store.clearSensitiveState()
            control.clearSensitiveState()
            clearRecallDecodedImageCache()
            Task { await images.clearSensitiveData() }
        }
    }

    private var controlBarTopPadding: CGFloat {
        RecallGeometry.controlBarTopPadding(safeAreaTop: overlayLayout.topSafeAreaInset)
    }

    private var audioPrefetchKey: String {
        guard !isLive, let moment = store.selectedMoment, moment.hasVisibleTranscript, let artifactID = moment.audioArtifactId else { return "" }
        return artifactID
    }

    private func bootstrap() async {
        guard await startDaemonOrReportFailure() != nil else { return }
        await permissions.requestInitialPermissionsOnce()
        if permissions.allGranted {
            AfterRayLog.info("bootstrap: permissions granted, ensuring recording")
            _ = await control.ensureRecording()
        } else {
            AfterRayLog.info(
                "bootstrap: permissions incomplete screen=\(permissions.screenRecording) mic=\(permissions.microphone) ax=\(permissions.accessibility) recordAudio=\(permissions.recordsAudio)"
            )
            await control.refreshStatus()
        }
        await store.loadTimeline()
    }

    private func toggleRecording() {
        Task {
            let changed = await control.toggleRecording()
            if changed { await store.refreshTimeline(preservingSelection: !isLive) }
        }
    }

    private func reload() {
        Task {
            guard await startDaemonOrReportFailure() != nil else { return }
            async let status: Void = control.refreshStatus()
            async let timeline: Void = store.refreshTimeline(preservingSelection: !isLive)
            _ = await (status, timeline)
        }
    }

    private func keepDaemonAlive() async {
        while !Task.isCancelled {
            if let restarted = await startDaemonOrReportFailure(), restarted {
                permissions.refresh()
                if permissions.allGranted, !DaemonSupervisor.shared.isCapturePausedForSystemLock {
                    _ = await control.ensureRecording()
                } else {
                    await control.refreshStatus()
                }
                await store.refreshTimeline(preservingSelection: !isLive)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Starts afterrayd. Returns whether this call launched a new process,
    /// or `nil` when startup failed and the user-visible error was recorded.
    @discardableResult
    private func startDaemonOrReportFailure() async -> Bool? {
        do {
            return try await DaemonSupervisor.shared.startIfNeeded()
        } catch let error as RuntimeError where !error.isUserVisibleFailure {
            return nil
        } catch {
            store.reportFailure(error.localizedDescription)
            await control.refreshStatus()
            return nil
        }
    }

    private func openSearchHit(_ hit: RecallSearchHit) {
        control.dismissSearch()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isLive = false
        }
        Task { await store.openSearchHit(hit) }
    }

    private func submitAsk() {
        control.dismissSearch()
        Task { await control.ask() }
    }

    private func openAskCitation(_ citation: AskCitation) {
        openSearchHit(citation.asSearchHit())
    }
}

private struct PermissionPanel: View {
    @ObservedObject var coordinator: SystemPermissionCoordinator

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Rectangle()
                            .fill(RecallPalette.ray)
                            .frame(width: 18, height: 2)
                        Text("LOCAL ONLY / AFTERRAY")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .tracking(1.1)
                    }
                    .foregroundStyle(RecallPalette.ray)
                    Text(coordinator.recordsAudio
                         ? "Three local permissions are required"
                         : "Two local permissions are required")
                        .font(.title2.weight(.semibold))
                    Text(coordinator.recordsAudio
                         ? "AfterRay starts recording automatically as soon as macOS grants all three. Nothing is uploaded."
                         : "Audio recording is off, so the microphone is optional. Screen and Accessibility are still required.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 9) {
                    ForEach(RequiredPermission.allCases) { permission in
                        if permission != .microphone || coordinator.recordsAudio || coordinator.microphone {
                            permissionRow(permission)
                        }
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
                    HStack {
                        Spacer()
                        Button("Check permissions") { coordinator.refresh() }
                            .buttonStyle(.borderedProminent)
                            .tint(RecallPalette.ray)
                    }
                }
            }
            .padding(28)
            .frame(width: 500)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.13), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
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
                    Task {
                        await coordinator.requestAgain(permission)
                        guard !isGranted(permission) else { return }
                        RecallOverlayController.shared.hide(returnFocus: false)
                        PermissionGuideController.shared.showAfterOpeningSettings(for: permission)
                        coordinator.openSettings(for: permission)
                    }
                }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func isGranted(_ permission: RequiredPermission) -> Bool {
        switch permission {
        case .screenRecording: coordinator.screenRecording
        case .microphone: coordinator.microphone
        case .accessibility: coordinator.accessibility
        }
    }
}

private struct AfterRaySettingsOverlay: View {
    @ObservedObject var model: AfterRaySettingsModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            AfterRaySettingsView(model: model, onClose: onClose)
                .recallGlass(in: .rounded(14))
                .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OverlaySettingsButton: View {
    let action: () -> Void

    var body: some View {
        RecallChromeIconButton(
            symbol: "gearshape",
            help: "Settings",
            action: action
        )
    }
}

private struct ImmersiveControlBar: View {
    @ObservedObject var model: AfterRayControlModel
    let onToggleRecording: () -> Void
    let onSearch: () -> Void
    let onClose: () -> Void
    @FocusState private var isSearchFocused: Bool

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
                    .focused($isSearchFocused)
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

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Close AfterRay")
        }
        .padding(.horizontal, 14)
        .frame(height: RecallGeometry.overlayChromeButtonSize)
        .recallGlass(in: .capsule)
    }

    private var statusLabel: String {
        if let message = model.message, !model.isRecording {
            return "Capture failed"
        }
        guard let status = model.status else { return "Daemon offline" }
        switch status.recordingState {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .stopping: return "Stopping"
        case .failed: return "Capture failed"
        }
    }
}

private struct ImmersiveAskBar: View {
    @ObservedObject var model: AfterRayControlModel
    let onAsk: () -> Void
    let onOpenSettings: () -> Void
    let onSelectCitation: (AskCitation) -> Void
    @FocusState private var isAskFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RecallPalette.ray.opacity(0.92))
                TextField("Ask about your day", text: $model.askQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .focused($isAskFocused)
                    .onSubmit(onAsk)
                if model.isAsking {
                    ProgressView().controlSize(.small)
                } else if !model.askQuestion.isEmpty {
                    Button(action: model.dismissAsk) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear question")
                }
            }
            .padding(.horizontal, 14)
            .frame(width: 420, height: 36)
            .recallGlass(in: .capsule)

            if model.isAsking || model.askAnswer != nil || model.askMessage != nil {
                AskAnswerPanel(
                    isAsking: model.isAsking,
                    answer: model.askAnswer,
                    error: model.askMessage,
                    onOpenSettings: onOpenSettings,
                    onSelectCitation: onSelectCitation,
                    onDismiss: model.dismissAsk
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }
}

private struct AskAnswerPanel: View {
    let isAsking: Bool
    let answer: AskAnswer?
    let error: String?
    let onOpenSettings: () -> Void
    let onSelectCitation: (AskCitation) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(panelTitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if isAsking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading today's memory…")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                }
            } else if let error {
                Text(error)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let answer {
                Text(answer.answer)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !answer.citations.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(answer.citations.prefix(3))) { citation in
                            Button {
                                onSelectCitation(citation)
                            } label: {
                                Text(citationChipTitle(citation))
                                    .lineLimit(1)
                            }
                            .buttonStyle(AskCitationChipStyle())
                            .help(citation.excerpt)
                        }
                    }
                }
                if answer.modelMissing {
                    Button("Open Settings", action: onOpenSettings)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(RecallPalette.ray)
                }
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .recallGlass(in: .rounded(10))
    }

    private var panelTitle: String {
        if isAsking { return "ASKING" }
        if answer?.modelMissing == true { return "MODEL MISSING" }
        if error != nil { return "ASK FAILED" }
        return "ANSWER"
    }

    private func citationChipTitle(_ citation: AskCitation) -> String {
        let time = Date(timeIntervalSince1970: TimeInterval(citation.capturedAtMs) / 1_000)
            .formatted(date: .omitted, time: .shortened)
        if citation.label.isEmpty {
            return time
        }
        return "\(time) · \(citation.label)"
    }
}

private struct AskCitationChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(configuration.isPressed ? 0.08 : 0.12), in: Capsule())
    }
}

private struct CaptureFailureBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(3)
            Button("Retry", action: onRetry)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 520)
        .recallGlass(in: .rounded(8))
        .help(message)
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
                LazyVStack(spacing: 2) {
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
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                        }
                        .buttonStyle(SearchResultButtonStyle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 390)
        }
        .recallGlass(in: .rounded(10))
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
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
