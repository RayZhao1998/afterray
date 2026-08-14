import AfterRayRecall
import AppKit
import Foundation

@MainActor
public final class SettingsPreviewModel: ObservableObject, AfterRaySettingsModeling {
    @Published public var settings: AppSettings? = AppSettings(
        dataDir: "/Users/demo/.afterray/v0-data",
        modelDir: "/Users/demo/.afterray/models",
        recordAudio: true,
        captureIntervalSeconds: 10
    )
    @Published public var library: ModelLibrary?
    @Published public var storage = AfterRayStorageSnapshot(
        vaultBytes: 1_800_000_000,
        modelBytes: 2_460_000_000,
        runtimeBytes: 420_000_000,
        volumeTotal: 1_000_000_000_000,
        volumeFree: 214_000_000_000
    )
    @Published public var message: String?
    @Published public var isRefreshing = false
    @Published public var downloadingID: String?
    @Published public var downloadProgress: Double?
    @Published public var downloadStatus: String?
    @Published public var isUpdatingAudio = false
    @Published public var isUpdatingExclusions = false
    @Published public var isClearingHistory = false
    @Published public var recordAudio = true
    @Published public var excludedBundleIds: [String] = []
    @Published public var recentJobs: [ModelJob] = [
        ModelJob(
            id: "job-asr",
            capability: "asr",
            adapter: "qwen3-asr",
            state: "failed",
            lastError: "model asset is missing"
        ),
        ModelJob(
            id: "job-ocr",
            capability: "ocr",
            adapter: "vision-ocr",
            state: "done"
        ),
    ]

    public var dataDirectoryPath: String { settings?.dataDir ?? "/tmp/afterray-data" }
    public var modelDirectoryPath: String { settings?.modelDir ?? "/tmp/afterray-models" }
    public var logDirectoryPath: String { AfterRayLog.directory.path }
    public var logFilePath: String { AfterRayLog.fileURL.path }

    public init(missingASR: Bool = true) {
        library = ModelLibrary(
            directory: modelDirectoryPath,
            packs: [
                ModelPack(
                    id: "asr",
                    name: "Qwen3 ASR",
                    capability: "asr",
                    path: "\(modelDirectoryPath)/Qwen3-ASR-1.7B",
                    present: !missingASR,
                    bytes: missingASR ? 0 : 4_200_000_000,
                    required: true,
                    note: "Qwen/Qwen3-ASR-1.7B · Rust/Candle",
                    expectedBytes: 4_200_000_000
                ),
                ModelPack(
                    id: "embedding",
                    name: "Text embeddings",
                    capability: "embedding",
                    path: "\(modelDirectoryPath)/nomic-embed-text-v1.5.Q4_K_M.gguf",
                    present: true,
                    bytes: 84_000_000,
                    required: true,
                    note: "nomic-embed-text v1.5 Q4 · llama.cpp",
                    expectedBytes: 84_000_000
                ),
                ModelPack(
                    id: "llm",
                    name: "Qwen3.8 27B",
                    capability: "llm",
                    path: "\(modelDirectoryPath)/qwen2.5-3b-instruct-q4_k_m.gguf",
                    present: false,
                    bytes: 0,
                    required: false,
                    note: "Powers overlay Q&A · optional for capture. Qwen3.8-27B (~16 GB Q4) via AFTERRAY_LLM_REPOSITORY / AFTERRAY_LLM_FILE when the GGUF lands. Fallback download is Qwen2.5-3B Instruct Q4.",
                    expectedBytes: 2_000_000_000
                ),
            ]
        )
    }

    public func refresh() async {
        isRefreshing = true
        try? await Task.sleep(for: .milliseconds(180))
        isRefreshing = false
        message = nil
    }

    public func setRecordAudio(_ enabled: Bool) async {
        recordAudio = enabled
        message = enabled ? "Audio recording is on." : "Audio recording is off."
    }

    public func excludeBundle(_ bundleID: String) async {
        if !excludedBundleIds.contains(bundleID) {
            excludedBundleIds.append(bundleID)
        }
    }

    public func includeBundle(_ bundleID: String) async {
        excludedBundleIds.removeAll { $0 == bundleID }
    }

    public func excludeFrontmostApp() async {
        await excludeBundle("com.apple.Safari")
    }

    public func clearHistory(_: HistoryScope) async {
        message = "Deleted preview history."
    }

    public func reveal(_ path: String) {
        message = "Would reveal \(path)"
    }

    public func download(packID: String?) async {
        downloadingID = packID ?? "all"
        downloadStatus = "Downloading \(packID ?? "models") · 15%"
        downloadProgress = 0.15
        try? await Task.sleep(for: .milliseconds(400))
        downloadStatus = "Downloading \(packID ?? "models") · 70%"
        downloadProgress = 0.7
        try? await Task.sleep(for: .milliseconds(400))
        if let packID, let current = library {
            library = ModelLibrary(
                directory: current.directory,
                packs: current.packs.map { pack in
                    guard pack.id == packID else { return pack }
                    return ModelPack(
                        id: pack.id,
                        name: pack.name,
                        capability: pack.capability,
                        path: pack.path,
                        present: true,
                        bytes: pack.expectedBytes ?? pack.bytes,
                        required: pack.required,
                        note: pack.note,
                        expectedBytes: pack.expectedBytes
                    )
                }
            )
        }
        downloadingID = nil
        downloadProgress = nil
        downloadStatus = nil
        message = "Preview marked \(packID ?? "models") as installed."
    }

    public func revealLogs() {
        message = "Would reveal \(logDirectoryPath)"
    }

    public func copyDiagnostics() {
        message = "Preview diagnostics copied."
    }
}
