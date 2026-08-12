import AfterRayRecall
import Foundation

@MainActor
final class DaemonSupervisor {
    static let shared = DaemonSupervisor()

    let socketPath: String
    private let defaultDataDirectory: URL
    private let defaultModelDirectory: URL
    private var process: Process?

    private init() {
        let environment = ProcessInfo.processInfo.environment
        if let repoRoot = Self.developmentRepoRoot() {
            socketPath = environment["AFTERRAY_SOCKET"]
                ?? repoRoot.appendingPathComponent(".afterray-dev/afterray.sock").path
            defaultDataDirectory = repoRoot.appendingPathComponent(".afterray/v0-data")
            defaultModelDirectory = repoRoot.appendingPathComponent(".afterray/models")
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("AfterRay", isDirectory: true)
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AfterRay")
            socketPath = environment["AFTERRAY_SOCKET"]
                ?? applicationSupport.appendingPathComponent("afterray.sock").path
            defaultDataDirectory = applicationSupport
            defaultModelDirectory = applicationSupport.appendingPathComponent("Models", isDirectory: true)
        }
    }

    func startIfNeeded() async throws {
        if await daemonIsReachable() { return }

        if let process, process.isRunning {
            process.terminate()
            self.process = nil
        }

        let socketURL = URL(fileURLWithPath: socketPath)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        let daemon = try resolveExecutable(
            environmentKey: "AFTERRAY_DAEMON",
            bundledName: "afterrayd",
            developmentPath: "target/debug/afterrayd"
        )
        let child = Process()
        child.executableURL = daemon
        var environment = ProcessInfo.processInfo.environment
        environment["AFTERRAY_SOCKET"] = socketPath
        environment["AFTERRAY_DATA_DIR"] = environment["AFTERRAY_DATA_DIR"]
            ?? defaultDataDirectory.path
        environment["AFTERRAY_CAPTURE_SHIM"] = try resolveExecutable(
            environmentKey: "AFTERRAY_CAPTURE_SHIM",
            bundledName: "AfterRayCaptureShim",
            developmentPath: "apps/AfterRayCaptureShim/.build/debug/AfterRayCaptureShim"
        ).path
        environment["AFTERRAY_NATIVE_MODEL_WORKER"] = try resolveExecutable(
            environmentKey: "AFTERRAY_NATIVE_MODEL_WORKER",
            bundledName: "afterray-native-model-worker",
            developmentPath: ".build/debug/afterray-native-model-worker"
        ).path
        environment["AFTERRAY_MODEL_WORKER"] = try resolveExecutable(
            environmentKey: "AFTERRAY_MODEL_WORKER",
            bundledName: "afterray_model_worker.py",
            developmentPath: "scripts/download-models/afterray_model_worker.py"
        ).path
        applyModelDefaults(to: &environment)
        child.environment = environment
        child.standardOutput = FileHandle.standardError
        child.standardError = FileHandle.standardError
        try child.run()
        process = child

        for _ in 0..<100 {
            if await daemonIsReachable() { return }
            if !child.isRunning {
                process = nil
                throw RuntimeError.daemonExited(child.terminationStatus)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        child.terminate()
        process = nil
        throw RuntimeError.daemonTimeout
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        self.process = nil
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func daemonIsReachable() async -> Bool {
        do {
            _ = try await UnixSocketDaemonClient(socketPath: socketPath).status()
            return true
        } catch {
            return false
        }
    }

    private func applyModelDefaults(to environment: inout [String: String]) {
        let defaults = [
            "AFTERRAY_WHISPER_MODEL": defaultModelDirectory
                .appendingPathComponent("ggml-large-v3-turbo-q5_0.bin"),
            "AFTERRAY_EMBEDDING_MODEL": defaultModelDirectory
                .appendingPathComponent("nomic-embed-text-v1.5.Q4_K_M.gguf"),
            "AFTERRAY_LLM_MODEL": defaultModelDirectory
                .appendingPathComponent("gemma-4-26b-a4b-it-4bit"),
        ]
        for (key, url) in defaults where environment[key] == nil {
            if FileManager.default.fileExists(atPath: url.path) {
                environment[key] = url.path
            }
        }

        let mlxBin = defaultModelDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("mlx-runtime/bin", isDirectory: true)
        if FileManager.default.fileExists(atPath: mlxBin.path) {
            environment["PATH"] = [mlxBin.path, environment["PATH"]]
                .compactMap { $0 }
                .joined(separator: ":")
        }
    }

    private static func developmentRepoRoot() -> URL? {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard bundleParent.lastPathComponent == ".afterray-dev" else { return nil }
        return bundleParent.deletingLastPathComponent()
    }

    private func resolveExecutable(
        environmentKey: String,
        bundledName: String,
        developmentPath: String
    ) throws -> URL {
        if let configured = ProcessInfo.processInfo.environment[environmentKey] {
            return URL(fileURLWithPath: configured)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(bundledName)
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(developmentPath)
        if FileManager.default.isExecutableFile(atPath: development.path) { return development }
        throw RuntimeError.missingExecutable(bundledName)
    }
}

private enum RuntimeError: LocalizedError {
    case missingExecutable(String)
    case daemonExited(Int32)
    case daemonTimeout

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name): "AfterRay helper is missing: \(name)"
        case .daemonExited(let status): "afterrayd exited during startup (status \(status))"
        case .daemonTimeout: "afterrayd did not become ready"
        }
    }
}
