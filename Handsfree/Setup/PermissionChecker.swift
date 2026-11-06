//
//  PermissionChecker.swift
//  Handsfree
//
//  Reads and requests the three permissions: Microphone, Accessibility and
//  Screen Recording. It only reads state and shows macOS's own dialogs; it
//  never changes a system setting itself (only the person at the Mac can).
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT): the permission half of
//  WindowPositionManager.swift. Kept: AXIsProcessTrusted for Accessibility,
//  CGPreflightScreenCaptureAccess for Screen Recording, AVCaptureDevice for the
//  microphone, and Clicky's rule of showing macOS's one-time prompt on the first
//  request and opening System Settings after that, so a person never gets the
//  prompt and the Settings page at once. Changed: "asked before" is remembered
//  across launches, so the panel can say "Ask macOS" or "Open Settings"
//  correctly. Removed: Clicky's window pinning and window shrinking.
//

import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech

@MainActor
enum PermissionChecker {
    private static let askedDefaultsKeyPrefix = "com.handsfree.hasAskedForPermission."

    static func status(of permission: PermissionKind) -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .notGranted
            }
        case .accessibility:
            if AXIsProcessTrusted() { return .granted }
            return hasAsked(.accessibility) ? .notGranted : .notAsked
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            return hasAsked(.screenRecording) ? .notGranted : .notAsked
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .notGranted
            }
        }
    }

    /// Shows macOS's own dialog the first time; after that, opens System Settings.
    static func request(_ permission: PermissionKind) {
        let currentStatus = status(of: permission)
        guard currentStatus != .granted else { return }
        if currentStatus == .notGranted {
            openSettings(for: permission)
            return
        }
        markAsked(permission)
        switch permission {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .speechRecognition:
            // Needs NSSpeechRecognitionUsageDescription in Info.plist (set in project.yml).
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }

    static func openSettings(for permission: PermissionKind) {
        guard let url = URL(string: permission.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func hasAsked(_ permission: PermissionKind) -> Bool {
        UserDefaults.standard.bool(forKey: askedDefaultsKeyPrefix + permission.rawValue)
    }

    private static func markAsked(_ permission: PermissionKind) {
        UserDefaults.standard.set(true, forKey: askedDefaultsKeyPrefix + permission.rawValue)
    }
}
