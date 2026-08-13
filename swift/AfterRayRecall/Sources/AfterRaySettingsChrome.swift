import AppKit
import SwiftUI

@MainActor
public protocol AfterRaySettingsModeling: ObservableObject {
    var settings: AppSettings? { get }
    var library: ModelLibrary? { get }
    var storage: AfterRayStorageSnapshot { get }
    var message: String? { get }
    var isRefreshing: Bool { get }
    var downloadingID: String? { get }
    var downloadProgress: Double? { get }
    var downloadStatus: String? { get }
    var isUpdatingAudio: Bool { get }
    var recordAudio: Bool { get }
    var dataDirectoryPath: String { get }
    var modelDirectoryPath: String { get }
    var logDirectoryPath: String { get }
    var logFilePath: String { get }

    func refresh() async
    func setRecordAudio(_ enabled: Bool) async
    func reveal(_ path: String)
    func download(packID: String?) async
    func revealLogs()
    func copyDiagnostics()
}

public struct AfterRayStorageSnapshot: Equatable, Sendable {
    public var vaultBytes: UInt64
    public var modelBytes: UInt64
    public var runtimeBytes: UInt64
    public var volumeTotal: UInt64
    public var volumeFree: UInt64

    public init(
        vaultBytes: UInt64 = 0,
        modelBytes: UInt64 = 0,
        runtimeBytes: UInt64 = 0,
        volumeTotal: UInt64 = 0,
        volumeFree: UInt64 = 0
    ) {
        self.vaultBytes = vaultBytes
        self.modelBytes = modelBytes
        self.runtimeBytes = runtimeBytes
        self.volumeTotal = volumeTotal
        self.volumeFree = volumeFree
    }

    public var afterrayBytes: UInt64 { vaultBytes + modelBytes + runtimeBytes }

    public var barSlices: (afterray: CGFloat, other: CGFloat, free: CGFloat) {
        let total = max(volumeTotal, afterrayBytes + volumeFree)
        guard total > 0 else { return (0, 0, 1) }
        let afterray = CGFloat(afterrayBytes) / CGFloat(total)
        let free = CGFloat(volumeFree) / CGFloat(total)
        let other = max(0, 1 - afterray - free)
        return (afterray, other, free)
    }

    public static func measure(dataDirectory: URL, modelDirectory: URL, runtimeDirectory: URL) -> Self {
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

    public static func itemBytes(at url: URL) -> UInt64 {
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

    public static func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

public enum AfterRaySettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general
    case models
    case advanced
    case diagnostics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .models: "AI Models"
        case .advanced: "Advanced"
        case .diagnostics: "Diagnostics"
        }
    }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .models: "cpu"
        case .advanced: "wrench.and.screwdriver"
        case .diagnostics: "stethoscope"
        }
    }

    var selectedIcon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .models: "cpu.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        case .diagnostics: "stethoscope"
        }
    }
}

public struct AfterRaySettingsView<Model: AfterRaySettingsModeling>: View {
    @ObservedObject var model: Model
    let onClose: () -> Void
    @State private var page: AfterRaySettingsPage
    @State private var copied = false

    public init(
        model: Model,
        onClose: @escaping () -> Void,
        initialPage: AfterRaySettingsPage = .general
    ) {
        self.model = model
        self.onClose = onClose
        _page = State(initialValue: initialPage)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            pageContent
        }
        .frame(width: 740, height: 560)
        .background(Color(red: 0.07, green: 0.07, blue: 0.075))
        .preferredColorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { await model.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(SettingsPressStyle())
                .help("Close settings")
            }
            .padding(.horizontal, 6)

            VStack(spacing: 2) {
                ForEach(AfterRaySettingsPage.allCases) { item in
                    sidebarRow(item)
                }
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 196)
        .background(Color.black.opacity(0.22))
    }

    private func sidebarRow(_ item: AfterRaySettingsPage) -> some View {
        let selected = page == item
        return Button {
            page = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? item.selectedIcon : item.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? .white : .white.opacity(0.55))
                    .frame(width: 16)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .white.opacity(0.72))
                Spacer(minLength: 0)
                if item == .models, missingRequiredCount > 0 {
                    Text("\(missingRequiredCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(.white.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                selected ? Color.white.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
    }

    private var missingRequiredCount: Int {
        model.library?.packs.filter { $0.required && !$0.present }.count ?? 0
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(page.title)
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch page {
                    case .general:
                        captureSection
                        storageSection
                    case .models:
                        modelsSection
                    case .advanced:
                        advancedSection
                    case .diagnostics:
                        diagnosticsSection
                    }
                    if let message = model.message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var captureSection: some View {
        SettingsGroup(title: "Capture") {
            SettingsRow(
                title: "Record audio",
                subtitle: "System audio and microphone for transcripts. Already-saved recordings stay in the vault."
            ) {
                Toggle("", isOn: Binding(
                    get: { model.recordAudio },
                    set: { enabled in Task { await model.setRecordAudio(enabled) } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.isUpdatingAudio)
            }
        }
    }

    private var storageSection: some View {
        SettingsGroup(title: "Storage") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    storageStat("AfterRay", AfterRayStorageSnapshot.byteCount(model.storage.afterrayBytes))
                    Spacer()
                    storageStat("Disk free", AfterRayStorageSnapshot.byteCount(model.storage.volumeFree), align: .trailing)
                }
                GeometryReader { geometry in
                    let slices = model.storage.barSlices
                    HStack(spacing: 1) {
                        Capsule().fill(Color.white.opacity(0.85))
                            .frame(width: max(geometry.size.width * slices.afterray, slices.afterray > 0 ? 2 : 0))
                        Capsule().fill(Color.white.opacity(0.18))
                            .frame(width: max(geometry.size.width * slices.other, slices.other > 0 ? 2 : 0))
                        Capsule().fill(Color.white.opacity(0.08))
                    }
                }
                .frame(height: 6)
                VStack(spacing: 6) {
                    storageLine("Memories", model.storage.vaultBytes)
                    storageLine("Models", model.storage.modelBytes)
                    storageLine("Runtime", model.storage.runtimeBytes)
                }
                HStack(spacing: 16) {
                    Button("Show Vault") { model.reveal(model.dataDirectoryPath) }
                    Button("Show Models") { model.reveal(model.modelDirectoryPath) }
                    Spacer()
                    Button("Refresh") { Task { await model.refresh() } }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status = model.downloadStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let progress = model.downloadProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }

            SettingsGroup(title: nil) {
                VStack(spacing: 0) {
                    SettingsRow(title: "On-device OCR", subtitle: "Apple Vision") {
                        Text("Built in")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    if let library = model.library {
                        ForEach(library.packs) { pack in
                            Divider().overlay(Color.white.opacity(0.06))
                            modelPackRow(pack)
                        }
                    } else if model.message == nil {
                        ProgressView().controlSize(.small).padding(16)
                    }
                }
            }

            HStack {
                Spacer()
                Button(model.downloadingID == "all" ? "Downloading…" : "Download Missing") {
                    Task { await model.download(packID: nil) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.14))
                .controlSize(.small)
                .disabled(model.downloadingID != nil || missingRequiredCount == 0)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Capture speed") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Capture speed", selection: .constant(AfterRayCaptureSpeedPlaceholder.fast)) {
                        ForEach(AfterRayCaptureSpeedPlaceholder.allCases) { speed in
                            Text(speed.label).tag(speed)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(true)
                    Text("Fast is the current default: a still every 10 seconds.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }

            SettingsGroup(title: "Vault") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.dataDirectoryPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Open in Finder") { model.reveal(model.dataDirectoryPath) }
                        Button("Change Location…") {}
                            .disabled(true)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    Text("Changing the database path is not available yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Logs") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.logFilePath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("AfterRay appends app and daemon output here. Attach this file when reporting a bug.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button("Reveal Log Folder") { model.revealLogs() }
                        Button(copied ? "Copied" : "Copy Report") {
                            model.copyDiagnostics()
                            copied = true
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                }
                .padding(16)
            }
        }
    }

    private func modelPackRow(_ pack: ModelPack) -> some View {
        let downloading = model.downloadingID == pack.id
        return SettingsRow(
            title: pack.name,
            subtitle: [capabilityLabel(pack.capability), pack.present ? AfterRayStorageSnapshot.byteCount(pack.bytes) : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
        ) {
            HStack(spacing: 8) {
                if downloading {
                    ProgressView().controlSize(.mini)
                    Text("Downloading")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(pack.present ? "Ready" : pack.required ? "Needed" : "Optional")
                        .font(.system(size: 12))
                        .foregroundStyle(pack.present ? Color.secondary : Color.white.opacity(0.7))
                }
                if !pack.present, !downloading {
                    Button("Download") {
                        Task { await model.download(packID: pack.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.downloadingID != nil)
                } else if pack.present {
                    Button("Show") { model.reveal(pack.path) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    private func storageStat(_ title: String, _ value: String, align: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
        }
    }

    private func storageLine(_ title: String, _ bytes: UInt64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(AfterRayStorageSnapshot.byteCount(bytes))
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func capabilityLabel(_ capability: String) -> String {
        switch capability {
        case "asr": "Transcription"
        case "embedding": "Search embeddings"
        case "llm": "Local assistant"
        default: capability.capitalized
        }
    }
}

private enum AfterRayCaptureSpeedPlaceholder: String, CaseIterable, Identifiable {
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

private struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            content
                .background(
                    Color.white.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
