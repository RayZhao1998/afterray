import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics
import Foundation

@MainActor
final class SystemPermissionCoordinator: ObservableObject {
    @Published private(set) var screenRecording = false
    @Published private(set) var microphone = false
    @Published private(set) var accessibility = false
    @Published private(set) var isRequesting = false

    var allGranted: Bool { screenRecording && microphone && accessibility }

    func requestRequiredPermissions() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }

        screenRecording = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphone = true
        case .notDetermined:
            microphone = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            microphone = false
        @unknown default:
            microphone = false
        }

        accessibility = checkAccessibility(prompt: true)
        refresh()
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = checkAccessibility(prompt: false)
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

    private func checkAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
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
