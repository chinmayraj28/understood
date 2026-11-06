import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Which macOS privacy permissions this app has, checked without changing any
/// setting and without showing a system prompt.
///
/// macOS grants these to the *responsible app*: Handsfree.app when installed,
/// or the terminal host (Orca on the development Mac) when run from a terminal.
/// Every sentence names that app, as System Settings shows it.
public enum Permissions {
    public enum State: String, Sendable {
        case granted
        case denied
        /// Never asked. Counts as missing: this app's users can't click Allow on a prompt.
        case notAsked = "not_asked"
    }

    public struct Status: Sendable, Equatable {
        /// "Accessibility", "Screen Recording" or "Microphone".
        public let name: String
        public let state: State
        /// What stops working without it, in a few words.
        public let neededFor: String
        /// One sentence that can be read aloud: how to grant it.
        public let howToGrant: String
        /// The raw checks behind the state, for logs and the first-run screen.
        public var detail: String = ""

        public var isGranted: Bool { state == .granted }
    }

    /// Every permission the app needs, with its current state.
    public static func checkAll() -> [Status] {
        let details = accessibilityDetails()
        var statuses = checkAll(accessibility: details.trusted && details.canPostEvents,
                                screenRecording: CGPreflightScreenCaptureAccess(), microphone: microphoneState())
        statuses[0].detail = "AXIsProcessTrusted \(details.trusted ? "yes" : "no"), CGPreflightPostEventAccess \(details.canPostEvents ? "yes" : "no")"
        return statuses
    }

    /// Both Accessibility checks. `trusted` (AXIsProcessTrusted) covers reading other
    /// apps' controls; `canPostEvents` (CGPreflightPostEventAccess) is the exact check for
    /// posting pointer and key events. Both come from the same Accessibility switch.
    public static func accessibilityDetails() -> (trusted: Bool, canPostEvents: Bool) {
        (AXIsProcessTrusted(), CGPreflightPostEventAccess())
    }

    /// The ones still missing, for the first-run flow to read out.
    public static func missing() -> [Status] { checkAll().filter { !$0.isGranted } }

    static func checkAll(accessibility: Bool, screenRecording: Bool, microphone: State) -> [Status] {
        [
            Status(
                name: "Accessibility", state: accessibility ? .granted : .denied,
                neededFor: "moving the pointer, clicking and typing",
                howToGrant: "To let me use the mouse and keyboard, \(settingsPath("Accessibility"))."),
            Status(
                name: "Screen Recording", state: screenRecording ? .granted : .denied,
                neededFor: "seeing what is on the screen",
                howToGrant: "To let me see the screen, \(settingsPath("Screen and System Audio Recording"))."),
            Status(
                name: "Microphone", state: microphone, neededFor: "hearing you",
                howToGrant: microphone == .notAsked
                    ? "\(hostAppName) hasn't been given the microphone yet, so when macOS asks, choose Allow, or \(settingsPath("Microphone"))."
                    : "To let me hear you, \(settingsPath("Microphone"))."),
        ]
    }

    static func microphoneState() -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// The error the hands throw when macOS would drop their events. One sentence.
    public static var accessibilityMissingSentence: String {
        "I can't use the mouse and keyboard because \(hostAppName) doesn't have Accessibility permission; to fix it, \(settingsPath("Accessibility"))."
    }

    static func settingsPath(_ pane: String) -> String {
        "open System Settings, go to Privacy and Security, then \(pane), and switch on \(hostAppName)"
    }

    // MARK: Which app holds our permissions

    /// The name System Settings shows for the app that holds our permissions.
    public static let hostAppName: String = {
        if let override = ProcessInfo.processInfo.environment["HANDSFREE_HOST_APP"], !override.isEmpty { return override }
        return appName(forPID: responsiblePID()) ?? "this app"
    }()

    /// The process macOS charges our permissions to.
    public static func responsiblePID() -> pid_t {
        // Private but stable since macOS 10.14; it is how TCC itself decides.
        typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            let responsible = unsafeBitCast(symbol, to: ResponsibleFunction.self)(getpid())
            if responsible > 0 { return responsible }
        }
        return getpid()
    }

    static func appName(forPID pid: pid_t) -> String? {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName, !name.isEmpty { return name }
        // A helper that isn't registered as an app (Orca's terminal host): read its bundle.
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = Bundle(path: String(path[..<range.lowerBound]) + ".app")
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}
