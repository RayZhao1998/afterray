import Foundation

public enum AfterRayLog {
    private static let lock = NSLock()
    private static var handle: FileHandle?
    private static let maximumBytes = 5 * 1_024 * 1_024

    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["AFTERRAY_LOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
        if bundleParent.lastPathComponent == ".afterray-dev" {
            return bundleParent
                .deletingLastPathComponent()
                .appendingPathComponent(".afterray/logs", isDirectory: true)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            return cwd.appendingPathComponent(".afterray/logs", isDirectory: true)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/AfterRay", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AfterRayLogs")
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("afterray.log")
    }

    public static func install() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeededLocked()
        if handle == nil {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            handle?.seekToEndOfFile()
        }
        let banner = """
        -------- AfterRay session \(timestamp()) \
        \(Bundle.main.bundleIdentifier ?? "afterray") \
        \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") \
        --------
        """
        writeLocked(banner + "\n")
    }

    public static func info(_ message: String, source: String = "app") {
        write(level: "info", source: source, message: message)
    }

    public static func error(_ message: String, source: String = "app") {
        write(level: "error", source: source, message: message)
    }

    public static func write(level: String, source: String, message: String) {
        let line = "\(timestamp()) [\(level)] [\(source)] \(message)\n"
        lock.lock()
        writeLocked(line)
        lock.unlock()
        fputs(line, stderr)
    }

    public static func appendRaw(_ text: String, source: String = "afterrayd") {
        guard !text.isEmpty else { return }
        let stamped = text.split(whereSeparator: \.isNewline)
            .map { "\(timestamp()) [info] [\(source)] \($0)" }
            .joined(separator: "\n")
        lock.lock()
        writeLocked(stamped + "\n")
        lock.unlock()
    }

    public static func recentText(limit: Int = 64 * 1_024) -> String {
        lock.lock()
        handle?.synchronizeFile()
        lock.unlock()
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        if data.count <= limit { return String(decoding: data, as: UTF8.self) }
        return String(decoding: data.suffix(limit), as: UTF8.self)
    }

    public static func diagnosticsReport() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        AfterRay diagnostics
        captured_at: \(timestamp())
        version: \(version)
        os: \(os)
        log_file: \(fileURL.path)
        log_directory: \(directory.path)

        --- recent log ---
        \(recentText())
        """
    }

    private static func writeLocked(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if handle == nil { return }
        rotateIfNeededLocked()
        handle?.write(data)
    }

    private static func rotateIfNeededLocked() {
        let path = fileURL.path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maximumBytes else { return }
        handle?.closeFile()
        handle = nil
        let rotated = directory.appendingPathComponent("afterray.log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
