import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics
import Foundation

@MainActor
final class SystemPermissionCoordinator: ObservableObject {
    private static let automaticRequestLedgerKey =
        "dev.afterray.permissions.automatic-requested.v1"

    @Published private(set) var screenRecording = false
    @Published private(set) var microphone = false
    @Published private(set) var accessibility = false
    @Published private(set) var isRequesting = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var allGranted: Bool { screenRecording && microphone && accessibility }

    func requestInitialPermissionsOnce() async {
        guard !isRequesting else { return }
        refresh()
        guard !allGranted else { return }

        isRequesting = true
        defer { isRequesting = false }

        if !screenRecording, reserveAutomaticRequest(for: .screenRecording) {
            screenRecording = CGRequestScreenCaptureAccess()
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = true
        case .notDetermined where reserveAutomaticRequest(for: .microphone):
            microphone = await AVCaptureDevice.requestAccess(for: .audio)
        case .notDetermined, .denied, .restricted:
            microphone = false
        @unknown default:
            microphone = false
        }

        if !accessibility, reserveAutomaticRequest(for: .accessibility) {
            requestAccessibilityAccess()
        }
        refresh()
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
    }

    func openSettings(for permission: RequiredPermission) {
        let anchor = switch permission {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func reserveAutomaticRequest(for permission: RequiredPermission) -> Bool {
        var requested = Set(
            defaults.stringArray(forKey: Self.automaticRequestLedgerKey) ?? []
        )
        guard requested.insert(permission.rawValue).inserted else { return false }
        defaults.set(requested.sorted(), forKey: Self.automaticRequestLedgerKey)
        return true
    }
}

enum RequiredPermission: String, CaseIterable, Identifiable {
    case screenRecording
    case microphone
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }

    var icon: String {
        switch self {
        case .screenRecording: "rectangle.inset.filled.and.person.filled"
        case .microphone: "mic.fill"
        case .accessibility: "accessibility"
        }
    }
}
