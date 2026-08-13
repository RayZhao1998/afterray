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
    @Published public var recordAudio = true

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
                    path: "\(modelDirectoryPath)/Qwen3-ASR-1.7B-8bit",
                    present: !missingASR,
                    bytes: missingASR ? 0 : 2_460_000_000,
                    required: true,
                    note: "mlx-community/Qwen3-ASR-1.7B-8bit",
                    expectedBytes: 2_460_000_000
                ),
                ModelPack(
                    id: "asr-whisper",
                    name: "Whisper ASR (fallback)",
                    capability: "asr",
                    path: "\(modelDirectoryPath)/ggml-large-v3-turbo-q5_0.bin",
                    present: true,
                    bytes: 547_000_000,
                    required: false,
                    note: "optional whisper.cpp fallback",
                    expectedBytes: 547_000_000
                ),
                ModelPack(
                    id: "embedding",
                    name: "Text embeddings",
                    capability: "embedding",
                    path: "\(modelDirectoryPath)/nomic-embed-text-v1.5.Q4_K_M.gguf",
                    present: true,
                    bytes: 274_000_000,
                    required: true,
                    expectedBytes: 84_000_000
                ),
                ModelPack(
                    id: "llm",
                    name: "Local LLM",
                    capability: "llm",
                    path: "\(modelDirectoryPath)/gemma-4-26b-a4b-it-4bit",
                    present: false,
                    bytes: 0,
                    required: false,
                    note: "Gemma 4 4bit · about 15 GB",
                    expectedBytes: 15_000_000_000
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

    public func reveal(_ path: String) {
        message = "Would reveal \(path)"
    }

    public func download(packID: String?) async {
        downloadingID = packID ?? "all"
        downloadStatus = "Preview download of \(packID ?? "missing models")…"
        downloadProgress = 0.15
        try? await Task.sleep(for: .milliseconds(400))
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
