import AfterRayRecall
import AppKit
import SwiftUI

extension Notification.Name {
    static let afterRayPreferencesDidChange = Notification.Name("dev.afterray.preferences-did-change")
}

enum AfterRayPreferences {
    static let recordAudioKey = "dev.afterray.recordAudio"

    static var recordAudio: Bool {
        get {
            guard UserDefaults.standard.object(forKey: recordAudioKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: recordAudioKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: recordAudioKey)
            NotificationCenter.default.post(name: .afterRayPreferencesDidChange, object: nil)
        }
    }
}

@MainActor
final class AfterRaySettingsController {
    static let shared = AfterRaySettingsController()
    static let windowLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))

    let model = AfterRaySettingsModel()

    private let panelSize = NSSize(width: 540, height: 720)
    private var panel: SettingsPanel?
    private(set) var isPresented = false

    var isVisible: Bool { isPresented && visibleSettingsWindow != nil }

    func show() {
        isPresented = true
        NSApp.unhideWithoutActivation()
        NSApp.activate(ignoringOtherApps: true)
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        presentFallbackPanel()
        promoteSettingsWindows()
        DispatchQueue.main.async { [weak self] in
            self?.promoteSettingsWindows()
        }
        Task { await model.refresh() }
    }

    func hide() {
        guard isPresented else { return }
        isPresented = false
        panel?.orderOut(nil)
        RecallOverlayController.shared.makeKeyIfVisible()
    }

    func promoteSettingsWindows() {
        guard isPresented else { return }
        for window in NSApp.windows where isSettingsWindow(window) {
            configure(window)
            window.orderFrontRegardless()
        }
        if let panel, panel.isVisible {
            configure(panel)
            panel.orderFrontRegardless()
        }
    }

    private var visibleSettingsWindow: NSWindow? {
        NSApp.windows.first { isSettingsWindow($0) && $0.isVisible } ?? panel
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        if window === panel { return true }
        if RecallOverlayController.shared.isOverlayWindow(window) { return false }
        let title = window.title
        let identifier = window.identifier?.rawValue ?? ""
        let className = String(describing: type(of: window))
        return title.localizedCaseInsensitiveContains("setting")
            || identifier.localizedCaseInsensitiveContains("setting")
            || className.localizedCaseInsensitiveContains("Settings")
    }

    private func presentFallbackPanel() {
        let panel = panel ?? makePanel()
        let hostingView = NSHostingView(rootView: AfterRaySettingsView(model: model) { [weak self] in
            self?.hide()
        })
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setFrame(NSRect(origin: origin(for: panelSize), size: panelSize), display: true)
        configure(panel)
        panel.orderFrontRegardless()
    }

    private func configure(_ window: NSWindow) {
        window.level = Self.windowLevel
        window.hidesOnDeactivate = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .moveToActiveSpace,
            .ignoresCycle,
        ]
    }

    private func makePanel() -> SettingsPanel {
        let panel = SettingsPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "AfterRay Settings"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.level = Self.windowLevel
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .moveToActiveSpace,
            .ignoresCycle,
        ]
        panel.delegate = SettingsWindowCloser.shared
        self.panel = panel
        return panel
    }

    private func origin(for size: NSSize) -> NSPoint {
        let screen = RecallOverlayController.shared.currentScreen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        return NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        )
    }
}

private final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class SettingsWindowCloser: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowCloser()

    func windowWillClose(_: Notification) {
        AfterRaySettingsController.shared.hide()
    }
}

struct SettingsWindowPromoter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SettingsWindowProbe()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SettingsWindowProbe)?.promote()
    }
}

private final class SettingsWindowProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        promote()
    }

    func promote() {
        guard AfterRaySettingsController.shared.isPresented, let window else { return }
        window.level = AfterRaySettingsController.windowLevel
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace])
        window.orderFrontRegardless()
    }
}

@MainActor
final class AfterRaySettingsModel: ObservableObject {
    @Published var settings: AppSettings?
    @Published var library: ModelLibrary?
    @Published var storage = AfterRayStorageSnapshot.measure(
        dataDirectory: DaemonSupervisor.shared.dataDirectory,
        modelDirectory: DaemonSupervisor.shared.modelDirectory,
        runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
    )
    @Published var message: String?
    @Published var isRefreshing = false
    @Published var downloadingID: String?
    @Published var downloadProgress: Double?
    @Published var isUpdatingAudio = false

    var recordAudio: Bool { settings?.recordAudio ?? AfterRayPreferences.recordAudio }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        storage = AfterRayStorageSnapshot.measure(
            dataDirectory: URL(fileURLWithPath: settings?.dataDir ?? DaemonSupervisor.shared.dataDirectory.path, isDirectory: true),
            modelDirectory: URL(fileURLWithPath: settings?.modelDir ?? DaemonSupervisor.shared.modelDirectory.path, isDirectory: true),
            runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
        )
        do {
            let daemon = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            async let nextSettings = daemon.settings()
            async let nextLibrary = daemon.modelLibrary()
            let loaded = try await (nextSettings, nextLibrary)
            settings = loaded.0
            library = loaded.1
            AfterRayPreferences.recordAudio = loaded.0.recordAudio
            storage = AfterRayStorageSnapshot.measure(
                dataDirectory: URL(fileURLWithPath: loaded.0.dataDir, isDirectory: true),
                modelDirectory: URL(fileURLWithPath: loaded.0.modelDir, isDirectory: true),
                runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
            )
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func setRecordAudio(_ enabled: Bool) async {
        guard enabled != recordAudio else { return }
        isUpdatingAudio = true
        defer { isUpdatingAudio = false }
        AfterRayPreferences.recordAudio = enabled
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(recordAudio: enabled)
            message = enabled
                ? "Audio recording is on."
                : "Audio recording is off. Existing recordings stay in your vault."
        } catch {
            AfterRayPreferences.recordAudio = !enabled
            message = error.localizedDescription
        }
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(folder)
    }

    func download(packID: String?) async {
        guard let script = Self.downloadScript else {
            message = "Download script is only available in the development checkout."
            reveal(library?.directory ?? DaemonSupervisor.shared.modelDirectory.path)
            return
        }
        downloadingID = packID ?? "all"
        downloadProgress = packID == nil ? nil : 0
        defer {
            downloadingID = nil
            downloadProgress = nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = script
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["AFTERRAY_MODEL_DIR"] = library?.directory ?? DaemonSupervisor.shared.modelDirectory.path
        if let packID, let target = Self.downloadTarget(for: packID) {
            environment["AFTERRAY_DOWNLOAD_ONLY"] = target
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            while process.isRunning {
                if let pack = library?.packs.first(where: { $0.id == packID }) {
                    let current = AfterRayStorageSnapshot.itemBytes(at: URL(fileURLWithPath: pack.path))
                    if let expected = pack.expectedBytes, expected > 0 {
                        downloadProgress = min(Double(current) / Double(expected), 0.99)
                    }
                }
                try await Task.sleep(for: .milliseconds(400))
            }
            if process.terminationStatus == 0 {
                message = packID == nil ? "Downloads finished." : "Download finished."
            } else {
                message = "Download exited with status \(process.terminationStatus)."
            }
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }

    private static func downloadTarget(for packID: String) -> String? {
        switch packID {
        case "asr": "asr"
        case "embedding": "embedding"
        case "llm": "llm"
        case "asr-whisper": "whisper"
        default: nil
        }
    }

    private static var downloadScript: URL? {
        let root = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            root.deletingLastPathComponent().appendingPathComponent("scripts/download-models/download.sh"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scripts/download-models/download.sh"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

struct AfterRayStorageSnapshot: Equatable {
    var vaultBytes: UInt64
    var modelBytes: UInt64
    var runtimeBytes: UInt64
    var volumeTotal: UInt64
    var volumeFree: UInt64

    var afterrayBytes: UInt64 { vaultBytes + modelBytes + runtimeBytes }
    var volumeUsedByOthers: UInt64 {
        volumeTotal.saturatingSubtract(volumeFree).saturatingSubtract(afterrayBytes)
    }

    static func measure(dataDirectory: URL, modelDirectory: URL, runtimeDirectory: URL) -> Self {
        let values = try? dataDirectory.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return Self(
            vaultBytes: itemBytes(at: dataDirectory),
            modelBytes: itemBytes(at: modelDirectory),
            runtimeBytes: itemBytes(at: runtimeDirectory),
            volumeTotal: UInt64(values?.volumeTotalCapacity ?? 0),
            volumeFree: UInt64(max(free, 0))
        )
    }

    static func itemBytes(at url: URL) -> UInt64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var total: UInt64 = 0
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += UInt64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}

struct AfterRaySettingsView: View {
    @ObservedObject var model: AfterRaySettingsModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.18)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    captureSection
                    storageSection
                    modelsSection
                    advancedSection
                    if let message = model.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 540, height: 720)
        .background(RecallPalette.background)
        .preferredColorScheme(.dark)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(RecallPalette.ray)
                Text("Local capture, storage, and models.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close settings")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var captureSection: some View {
        SettingsSection(
            title: "Capture",
            subtitle: "AfterRay records this Mac only. Nothing is uploaded."
        ) {
            Toggle(isOn: Binding(
                get: { model.recordAudio },
                set: { enabled in Task { await model.setRecordAudio(enabled) } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record audio")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("System audio and microphone, used for transcripts. Turning this off skips new audio until you switch it back on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(model.isUpdatingAudio)
        }
    }

    private var storageSection: some View {
        SettingsSection(
            title: "Storage",
            subtitle: "How much AfterRay is using on this disk."
        ) {
            StorageUsageCard(snapshot: model.storage)
            HStack {
                Button("Reveal Vault") {
                    model.reveal(model.settings?.dataDir ?? DaemonSupervisor.shared.dataDirectory.path)
                }
                Button("Reveal Models") {
                    model.reveal(model.settings?.modelDir ?? DaemonSupervisor.shared.modelDirectory.path)
                }
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var modelsSection: some View {
        SettingsSection(
            title: "Models",
            subtitle: "Each capability uses a local file. AfterRay never calls a remote model API."
        ) {
            VStack(spacing: 8) {
                builtinModelRow(
                    name: "On-device OCR",
                    detail: "Apple Vision · built in",
                    present: true
                )
                if let library = model.library {
                    ForEach(library.packs) { pack in
                        modelPackRow(pack)
                    }
                } else if model.message == nil {
                    ProgressView().controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button(model.downloadingID == "all" ? "Downloading…" : "Download Missing") {
                    Task { await model.download(packID: nil) }
                }
                .disabled(model.downloadingID != nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var advancedSection: some View {
        SettingsSection(
            title: "Advanced",
            subtitle: "These controls are listed now so the page is complete. Changing them is not wired yet."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Capture speed")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Picker("Capture speed", selection: .constant(CaptureSpeedPlaceholder.fast)) {
                    ForEach(CaptureSpeedPlaceholder.allCases) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(true)
                Text("Fast is the current default: a still every 10 seconds. Balanced and Light will space captures further apart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().opacity(0.15)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Vault location")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(model.settings?.dataDir ?? DaemonSupervisor.shared.dataDirectory.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Open in Finder") {
                            model.reveal(model.settings?.dataDir ?? DaemonSupervisor.shared.dataDirectory.path)
                        }
                        Button("Change Location…") {}
                            .disabled(true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("Changing the database path will arrive with a migration. Opening the current folder works now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func builtinModelRow(name: String, detail: String, present: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? Color.green : RecallPalette.ray)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("Built in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func modelPackRow(_ pack: ModelPack) -> some View {
        let downloading = model.downloadingID == pack.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: pack.present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(pack.present ? Color.green : RecallPalette.ray)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(pack.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(pack.present ? byteCount(pack.bytes) : pack.required ? "Missing" : "Optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(capabilityLabel(pack.capability))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(RecallPalette.ray.opacity(0.86))
                if let note = pack.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if downloading {
                    if let progress = model.downloadProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    Text(model.downloadProgress == nil ? "Starting download…" : "Downloading…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show") { model.reveal(pack.path) }
                    if !pack.present || downloading {
                        Button(downloading ? "Downloading…" : "Download") {
                            Task { await model.download(packID: pack.id) }
                        }
                        .disabled(model.downloadingID != nil)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func capabilityLabel(_ capability: String) -> String {
        switch capability {
        case "asr": "Transcription"
        case "embedding": "Search embeddings"
        case "llm": "Local assistant"
        default: capability.capitalized
        }
    }

    private func byteCount(_ bytes: UInt64) -> String {
        AfterRayStorageSnapshot.byteCount(bytes)
    }
}

private enum CaptureSpeedPlaceholder: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .light: "Light"
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
    }
}

private struct StorageUsageCard: View {
    let snapshot: AfterRayStorageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AfterRay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AfterRayStorageSnapshot.byteCount(snapshot.afterrayBytes))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Disk free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AfterRayStorageSnapshot.byteCount(snapshot.volumeFree))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                }
            }

            GeometryReader { geometry in
                let slices = snapshot.barSlices
                HStack(spacing: 1) {
                    bar(width: geometry.size.width * slices.afterray, color: RecallPalette.ray)
                    bar(width: geometry.size.width * slices.other, color: .white.opacity(0.22))
                    bar(width: geometry.size.width * slices.free, color: Color(red: 0.24, green: 0.48, blue: 0.38))
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 4) {
                legend("Memories", snapshot.vaultBytes)
                legend("Models", snapshot.modelBytes)
                legend("MLX runtime", snapshot.runtimeBytes)
                if snapshot.volumeTotal > 0 {
                    Text("This disk: \(AfterRayStorageSnapshot.byteCount(snapshot.volumeTotal)) total")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bar(width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(width, width > 0 ? 2 : 0), height: 10)
    }

    private func legend(_ title: String, _ bytes: UInt64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(AfterRayStorageSnapshot.byteCount(bytes))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

extension AfterRayStorageSnapshot {
    var barSlices: (afterray: CGFloat, other: CGFloat, free: CGFloat) {
        let total = max(volumeTotal, afterrayBytes + volumeFree)
        guard total > 0 else { return (0, 0, 1) }
        let afterray = CGFloat(afterrayBytes) / CGFloat(total)
        let free = CGFloat(volumeFree) / CGFloat(total)
        let other = max(0, 1 - afterray - free)
        return (afterray, other, free)
    }

    static func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
