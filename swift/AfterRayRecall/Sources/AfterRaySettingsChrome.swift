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
    var recentJobs: [ModelJob] { get }

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

    public var otherBytes: UInt64 {
        let used = volumeTotal > volumeFree ? volumeTotal - volumeFree : 0
        return used > afterrayBytes ? used - afterrayBytes : 0
    }

    public var diskShareText: String {
        guard volumeTotal > 0 else { return "Disk size is unavailable." }
        let percent = Double(afterrayBytes) / Double(volumeTotal) * 100
        let share = percent < 0.1
            ? "less than 0.1%"
            : String(format: "%.1f%%", percent)
        return "AfterRay is \(share) of this \(Self.byteCount(volumeTotal)) disk."
    }

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
        .frame(width: 760, height: 570)
        .background(Color(red: 0.052, green: 0.050, blue: 0.056))
        .preferredColorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RecallPalette.ray.opacity(0.9))
                .frame(height: 2)
        }
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
                        .frame(width: 28, height: 28)
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
                selected ? Color.white.opacity(0.075) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(RecallPalette.ray)
                        .frame(width: 2, height: 18)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
    }

    private var missingRequiredCount: Int {
        model.library?.packs.filter { $0.required && !$0.present }.count ?? 0
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("AFTERRAY / SETTINGS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(RecallPalette.ray)
                Text(page.title)
                    .font(.system(size: 23, weight: .semibold))
            }
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
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "This disk") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        storageStat("AfterRay uses", AfterRayStorageSnapshot.byteCount(model.storage.afterrayBytes))
                        Spacer()
                        storageStat(
                            "Still free",
                            AfterRayStorageSnapshot.byteCount(model.storage.volumeFree),
                            align: .trailing
                        )
                    }
                    StorageDiskBar(snapshot: model.storage)
                    VStack(alignment: .leading, spacing: 7) {
                        storageLegend("AfterRay", model.storage.afterrayBytes, StorageDiskBar.afterrayColor)
                        storageLegend("Other files on this disk", model.storage.otherBytes, StorageDiskBar.otherColor)
                        storageLegend("Free space", model.storage.volumeFree, StorageDiskBar.freeColor)
                    }
                    Text(model.storage.diskShareText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }

            SettingsGroup(title: "Inside AfterRay") {
                VStack(spacing: 0) {
                    storageLine("Memories", model.storage.vaultBytes)
                    Divider().overlay(Color.white.opacity(0.06))
                    storageLine("Models", model.storage.modelBytes)
                    Divider().overlay(Color.white.opacity(0.06))
                    storageLine("Runtime", model.storage.runtimeBytes)
                }
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
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The Qwen3.8 assistant pack powers overlay Q&A. Capture, OCR, and search still work if it is missing.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.downloadingID != nil, let status = model.downloadStatus {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        if let percent = percentLabel(model.downloadProgress) {
                            Text(percent)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.82))
                                .monospacedDigit()
                        }
                    }
                    ProgressView(value: model.downloadProgress ?? 0)
                        .progressViewStyle(.linear)
                }
            }

            if !model.recentJobs.isEmpty {
                SettingsGroup(title: "Recent inference") {
                    VStack(spacing: 0) {
                        ForEach(Array(model.recentJobs.enumerated()), id: \.element.id) { index, job in
                            if index > 0 {
                                Divider().overlay(Color.white.opacity(0.06))
                            }
                            SettingsRow(
                                title: jobTitle(job),
                                subtitle: jobSubtitle(job)
                            ) {
                                Text(jobStateLabel(job.state))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(job.state == "done" ? Color.secondary : Color.white.opacity(0.78))
                            }
                        }
                    }
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
                .tint(RecallPalette.ray.opacity(0.88))
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
            || model.library?.download?.packId == pack.id
        return SettingsRow(
            title: pack.name,
            subtitle: [
                capabilityLabel(pack.capability),
                pack.note,
                pack.present ? AfterRayStorageSnapshot.byteCount(pack.bytes) : nil,
            ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        ) {
            HStack(spacing: 8) {
                if downloading {
                    ProgressView().controlSize(.mini)
                    Text(percentLabel(model.downloadProgress) ?? "Downloading")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(packStatus(pack))
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

    private func packStatus(_ pack: ModelPack) -> String {
        if pack.present { return "Ready" }
        if pack.bytes > 0 { return "Incomplete" }
        return pack.required ? "Needed" : "Optional"
    }

    private func jobTitle(_ job: ModelJob) -> String {
        switch job.capability {
        case "asr": "Qwen3 ASR"
        case "ocr": "OCR"
        case "embedding": "Embeddings"
        case "llm": "Qwen3.8 27B"
        default: job.capability
        }
    }

    private func jobSubtitle(_ job: ModelJob) -> String {
        if let error = job.lastError, !error.isEmpty {
            return error
        }
        return job.adapter
    }

    private func jobStateLabel(_ state: String) -> String {
        switch state {
        case "done": "OK"
        case "failed": "Failed"
        case "running": "Running"
        case "pending": "Queued"
        case "cancelled": "Cancelled"
        default: state
        }
    }

    private func percentLabel(_ progress: Double?) -> String? {
        guard let progress else { return nil }
        return "\(Int((progress * 100).rounded(.down)))%"
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
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func storageLegend(_ title: String, _ bytes: UInt64, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
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

private struct StorageDiskBar: View {
    let snapshot: AfterRayStorageSnapshot

    static let afterrayColor = RecallPalette.ray
    static let otherColor = Color.white.opacity(0.28)
    static let freeColor = Color.white.opacity(0.10)

    var body: some View {
        let slices = snapshot.barSlices
        GeometryReader { geometry in
            HStack(spacing: 1) {
                slice(width: geometry.size.width * slices.afterray, color: Self.afterrayColor, minimum: snapshot.afterrayBytes > 0)
                slice(width: geometry.size.width * slices.other, color: Self.otherColor, minimum: snapshot.otherBytes > 0)
                slice(width: geometry.size.width * slices.free, color: Self.freeColor, minimum: snapshot.volumeFree > 0)
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .accessibilityLabel(snapshot.diskShareText)
    }

    private func slice(width: CGFloat, color: Color, minimum: Bool) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(width, minimum ? 3 : 0), height: 8)
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
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.48))
                    .padding(.horizontal, 4)
            }
            content
                .background(
                    Color.white.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.055), lineWidth: 1)
                }
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
        .padding(.vertical, 12)
    }
}
