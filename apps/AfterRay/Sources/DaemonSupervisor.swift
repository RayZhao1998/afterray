import Foundation

@MainActor
final class DaemonSupervisor {
    static let shared = DaemonSupervisor()

    let socketPath: String
    private var process: Process?

    private init() {
        socketPath = ProcessInfo.processInfo.environment["AFTERRAY_SOCKET"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("afterray-v0.sock")
    }

    func startIfNeeded() async throws {
        if FileManager.default.fileExists(atPath: socketPath) { return }

        let daemon = try resolveExecutable(
            environmentKey: "AFTERRAY_DAEMON",
            bundledName: "afterrayd",
            developmentPath: "target/debug/afterrayd"
        )
        let child = Process()
        child.executableURL = daemon
        var environment = ProcessInfo.processInfo.environment
        environment["AFTERRAY_SOCKET"] = socketPath
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
        child.environment = environment
        child.standardOutput = FileHandle.standardError
        child.standardError = FileHandle.standardError
        try child.run()
        process = child

        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socketPath) { return }
            if !child.isRunning {
                throw RuntimeError.daemonExited(child.terminationStatus)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        child.terminate()
        throw RuntimeError.daemonTimeout
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
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
