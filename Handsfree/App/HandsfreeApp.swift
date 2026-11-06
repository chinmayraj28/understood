//
//  HandsfreeApp.swift
//  Handsfree
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT, Farza): leanring_buddyApp.swift.
//
//  A menu bar app: no Dock icon and no main window (LSUIElement in Info.plist).
//  Kept from Clicky: the SwiftUI App with an empty Settings scene to satisfy
//  SwiftUI, and an NSApplicationDelegate that builds everything at launch.
//  Removed: the Sparkle updater, PostHog analytics, and registering as a login
//  item (this app must never install itself to start at login without asking).
//

import AppKit
import SwiftUI

@main
struct HandsfreeApp: App {
    @NSApplicationDelegateAdaptor(HandsfreeAppDelegate.self) var appDelegate

    var body: some Scene {
        // Never shown: LSUIElement removes the app menu. SwiftUI needs one scene.
        Settings { EmptyView() }
    }
}

@MainActor
final class HandsfreeAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
        let coordinator = AppCoordinator(options: options)
        self.coordinator = coordinator
        coordinator.start()
    }

    /// Quitting waits for the shutdown hooks (at most 4 s), so the hands are released
    /// and other apps' settings are restored before the process ends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        coordinator.shutDown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Called when Handsfree is opened again while it is running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.reopened()
        return false
    }
}
