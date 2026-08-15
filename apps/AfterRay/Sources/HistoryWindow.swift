import AfterRayRecall
import AppKit
import SwiftUI

/// The services the overlay and the standalone history window share. Both
/// faces must observe the same store — a popped-out panel showing different
/// data from the overlay would be worse than no window at all.
///
/// Created lazily by whichever face mounts first; the root view adopts these
/// instead of building private copies.
@MainActor
final class AfterRayServices {
    static let shared = AfterRayServices()

    let daemon: UnixSocketDaemonClient
    let images: RecallImageRepository
    let store: RecallStore
    let control: AfterRayControlModel
    let chat: AfterRayChatModel
    let audioPlayer: ArtifactAudioPlayer

    private init() {
        let daemon = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
        let repository = RecallImageRepository(daemon: daemon)
        self.daemon = daemon
        images = repository
        store = RecallStore(daemon: daemon)
        control = AfterRayControlModel(daemon: daemon)
        chat = AfterRayChatModel(daemon: daemon)
        audioPlayer = ArtifactAudioPlayer(repository: repository)
    }
}

/// The history panel as a real window: normal level, normal Mission
/// Control/Cmd-Tab behaviour, survives the overlay closing. This exists for
/// cross-referencing — reading past summaries beside another app is
/// impossible when the panel lives only inside a full-screen overlay.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AfterRay History"
        window.minSize = NSSize(width: 360, height: 320)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.045, green: 0.04, blue: 0.05, alpha: 1)
        window.contentView = NSHostingView(rootView: HistoryWindowRoot())
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("dev.afterray.history-window")
        self.window = window

        // A visible standard window deserves standard app behaviour: a Dock
        // icon and a Cmd-Tab entry while it is open. The app returns to
        // menu-bar-only when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task {
            await AfterRayServices.shared.store.ensureSummaryHistory(
                containing: Int64(Date().timeIntervalSince1970 * 1_000),
                refresh: true
            )
        }
    }

    func windowWillClose(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct HistoryWindowRoot: View {
    @ObservedObject private var store = AfterRayServices.shared.store

    var body: some View {
        DaySummaryPanel(
            style: .window,
            summaries: store.summaryHistory,
            playheadMs: store.playheadMs,
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000),
            hasMore: store.summaryHistoryHasMore,
            isLoadingMore: store.isLoadingSummaryHistory,
            followPulse: 0,
            onSelectSlot: { slotStartMs in
                // Jumping to a moment is an overlay affair: bring it up on
                // the selected half hour. The window stays where it is.
                AfterRayServices.shared.store.select(playheadMs: slotStartMs)
                RecallOverlayController.shared.show()
            },
            onLoadMore: {
                Task { await AfterRayServices.shared.store.loadOlderSummaryHistory() }
            }
        )
        .preferredColorScheme(.dark)
    }
}
