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

    var recordAudio: Bool { settings?.recordAudio ?? AfterRayPreferences.recordAudio }
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
        downloadStatus = packID == nil ? "Starting downloads…" : "Starting \(displayName(for: packID))…"
        message = nil
        defer {
            downloadingID = nil
            downloadProgress = nil
            downloadStatus = nil
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = script
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.downloadPATH(from: environment["PATH"])
        environment["HOME"] = NSHomeDirectory()
        environment["AFTERRAY_MODEL_DIR"] = library?.directory ?? DaemonSupervisor.shared.modelDirectory.path
        environment["AFTERRAY_MLX_RUNTIME"] = DaemonSupervisor.shared.mlxRuntimeDirectory.path
        environment["PYTHONUNBUFFERED"] = "1"
        if let packID, let target = Self.downloadTarget(for: packID) {
            environment["AFTERRAY_DOWNLOAD_ONLY"] = target
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        var log = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                log += chunk
                self?.downloadStatus = Self.latestLogLine(from: log)
            }
        }

        do {
            try process.run()
            while process.isRunning {
                if let pack = library?.packs.first(where: { $0.id == packID }) {
                    let current = AfterRayStorageSnapshot.itemBytes(at: URL(fileURLWithPath: pack.path))
                    if let expected = pack.expectedBytes, expected > 0, current > 0 {
                        downloadProgress = min(Double(current) / Double(expected), 0.99)
                    }
                }
                try await Task.sleep(for: .milliseconds(400))
            }
            output.fileHandleForReading.readabilityHandler = nil
            if let leftover = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                log += leftover
            }
            AfterRayLog.info(log, source: "download")
            if process.terminationStatus == 0 {
                message = packID == nil ? "Downloads finished." : "\(displayName(for: packID)) is ready."
            } else {
                let detail = Self.latestLogLine(from: log)
                message = detail.isEmpty
                    ? "Download failed (exit \(process.terminationStatus))."
                    : "Download failed: \(detail)"
                AfterRayLog.error(message ?? "download failed", source: "download")
            }
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            message = error.localizedDescription
            AfterRayLog.error(error.localizedDescription, source: "download")
        }
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

    private static func downloadTarget(for packID: String) -> String? {
        switch packID {
        case "asr": "asr"
        case "embedding": "embedding"
        case "llm": "llm"
        case "asr-whisper": "whisper"
        default: nil
        }
    }

    private static func downloadPATH(from current: String?) -> String {
        let extras = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let existing = (current ?? "").split(separator: ":").map(String.init)
        return (extras + existing).joined(separator: ":")
    }

    private static func latestLogLine(from log: String) -> String {
        log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
            .map { String($0) } ?? log.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var downloadScript: URL? {
        var candidates: [URL] = []
        if let repo = DaemonSupervisor.shared.repositoryRoot {
            candidates.append(repo.appendingPathComponent("scripts/download-models/download.sh"))
        }
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(
            bundleParent.deletingLastPathComponent().appendingPathComponent("scripts/download-models/download.sh")
        )
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scripts/download-models/download.sh")
        )
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

