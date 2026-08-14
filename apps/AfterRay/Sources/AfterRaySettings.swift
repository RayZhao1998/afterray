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
final class AfterRaySettingsController: ObservableObject {
    static let shared = AfterRaySettingsController()

    let model = AfterRaySettingsModel()
    @Published private(set) var isPresented = false

    var isVisible: Bool { isPresented }

    func show() {
        isPresented = true
        if !RecallOverlayController.shared.isVisible {
            RecallOverlayController.shared.show()
        }
        Task { await model.refresh() }
    }

    func hide() {
        isPresented = false
    }
}

@MainActor
final class AfterRaySettingsModel: ObservableObject, AfterRaySettingsModeling {
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
    @Published var downloadStatus: String?
    @Published var isUpdatingAudio = false
    @Published var isUpdatingExclusions = false
    @Published var isClearingHistory = false
    @Published var recentJobs: [ModelJob] = []

    var recordAudio: Bool { settings?.recordAudio ?? AfterRayPreferences.recordAudio }
    var excludedBundleIds: [String] { settings?.excludedBundleIds ?? [] }
    var dataDirectoryPath: String {
        settings?.dataDir ?? DaemonSupervisor.shared.dataDirectory.path
    }
    var modelDirectoryPath: String {
        settings?.modelDir ?? DaemonSupervisor.shared.modelDirectory.path
    }
    var logDirectoryPath: String { AfterRayLog.directory.path }
    var logFilePath: String { AfterRayLog.fileURL.path }

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
            async let nextJobs = daemon.jobs()
            let loaded = try await (nextSettings, nextLibrary, nextJobs)
            settings = loaded.0
            library = loaded.1
            recentJobs = Array(loaded.2.suffix(8).reversed())
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

    func excludeBundle(_ bundleID: String) async {
        var next = excludedBundleIds
        guard !bundleID.isEmpty, !next.contains(bundleID) else { return }
        next.append(bundleID)
        await saveExclusions(next, message: "Excluded \(bundleID).")
    }

    func includeBundle(_ bundleID: String) async {
        await saveExclusions(excludedBundleIds.filter { $0 != bundleID }, message: "Included \(bundleID) again.")
    }

    func excludeFrontmostApp() async {
        guard
            let application = NSWorkspace.shared.frontmostApplication,
            let bundleID = application.bundleIdentifier,
            bundleID != "dev.afterray.app"
        else {
            message = "Could not read the frontmost app."
            return
        }
        await excludeBundle(bundleID)
    }

    func clearHistory(_ scope: HistoryScope) async {
        isClearingHistory = true
        defer { isClearingHistory = false }
        do {
            let result = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).clearHistory(scope: scope)
            message = "Deleted \(result.deleted) moment\(result.deleted == 1 ? "" : "s")."
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveExclusions(_ ids: [String], message: String) async {
        isUpdatingExclusions = true
        defer { isUpdatingExclusions = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(recordAudio: nil, excludedBundleIds: ids)
            self.message = message
        } catch {
            self.message = error.localizedDescription
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
            ).updateSettings(recordAudio: enabled, excludedBundleIds: nil)
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
        downloadingID = packID ?? "all"
        downloadProgress = 0
        downloadStatus = packID == nil ? "Starting downloads…" : "Starting \(displayName(for: packID))…"
        message = nil
        defer {
            downloadingID = nil
            downloadProgress = nil
            downloadStatus = nil
        }

        let socket = DaemonSupervisor.shared.socketPath
        let progress = Task { @MainActor in
            while !Task.isCancelled {
                if let next = try? await UnixSocketDaemonClient(socketPath: socket).modelLibrary() {
                    library = next
                    applyDownloadProgress(next.download, fallbackPackID: packID)
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }

        do {
            library = try await UnixSocketDaemonClient(socketPath: socket).downloadModels(packID: packID)
            AfterRayLog.info("downloaded \(packID ?? "missing models")", source: "download")
            message = packID == nil ? "Downloads finished." : "\(displayName(for: packID)) is ready."
        } catch {
            message = error.localizedDescription
            AfterRayLog.error(error.localizedDescription, source: "download")
        }
        progress.cancel()
        await refresh()
    }

    func revealLogs() {
        reveal(AfterRayLog.directory.path)
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AfterRayLog.diagnosticsReport(), forType: .string)
        AfterRayLog.info("diagnostics report copied")
    }

    private func displayName(for packID: String?) -> String {
        library?.packs.first(where: { $0.id == packID })?.name ?? "model"
    }

    private func applyDownloadProgress(_ download: ModelDownloadProgress?, fallbackPackID: String?) {
        guard let download else { return }
        if let fraction = download.fraction {
            downloadProgress = min(fraction, 0.99)
        }
        let name = displayName(for: download.packId.isEmpty ? fallbackPackID : download.packId)
        if let percent = download.percent {
            downloadStatus = "Downloading \(name) · \(percent)%"
        } else if download.totalFiles > 0 {
            downloadStatus = "Downloading \(name) · \(download.completedFiles)/\(download.totalFiles) files"
        } else {
            downloadStatus = "Downloading \(name)…"
        }
    }
}

