//
//  OverlayWindow.swift
//  Handsfree
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT, Farza): OverlayWindow.swift
//  (the OverlayWindow class and OverlayWindowManager).
//
//  One transparent, borderless window per screen, above everything, that never
//  takes focus and lets every click through. Kept from Clicky exactly: the
//  window level, click-through, the collection behaviour that follows the user
//  across Spaces and full-screen apps, and never becoming key or main.
//  Added: kept out of screenshots (sharingType = .none) so the screen agent
//  never sees our halo and captions on top of the app it is operating, and
//  rebuilt when displays are plugged in or rearranged.
//

import AppKit
import SwiftUI

final class OverlayWindow: NSWindow {
    init(screen: NSScreen, isCapturable: Bool) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        // Above menus, pop-ups and the Dock, so the companion is never hidden.
        level = .screenSaver
        // Every click passes through to the app underneath. This is what makes
        // a window covering the whole screen safe.
        ignoresMouseEvents = true
        // On every Space, not moved by Mission Control, shown over full-screen apps,
        // and left out of Command-Tab and window cycling.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hasShadow = false
        // A menu bar app is never "active"; without this the window would hide.
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        // Keep the overlay out of screenshots and screen recordings. With .none,
        // the window server leaves this window out of captures by other processes.
        // (Verified on this Mac; see docs/APP.md, "Keeping the overlay out of screenshots".)
        sharingType = isCapturable ? .readOnly : .none
        // Not something to click or read: keep it out of the accessibility tree, so a
        // lookup at the pointer never names our overlay instead of the app beneath.
        setAccessibilityElement(false)

        setFrame(screen.frame, display: true)
    }

    // Never take keyboard focus from the app the user (or the agent) is working in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Creates one overlay per screen and keeps them in step with the displays.
@MainActor
final class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    private var screenChangeObserver: NSObjectProtocol?
    private var makeContent: ((NSScreen) -> AnyView)?
    private var isCapturable = false

    /// Shows an overlay on every screen. `makeContent` builds the SwiftUI view for one screen.
    func showOverlays(isCapturable: Bool, makeContent: @escaping (NSScreen) -> AnyView) {
        self.isCapturable = isCapturable
        self.makeContent = makeContent
        rebuild()
        if screenChangeObserver == nil {
            screenChangeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }

    func hideOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// The window numbers of the overlays, for checks that they stay out of captures.
    var windowNumbers: [Int] { overlayWindows.map(\.windowNumber) }

    private func rebuild() {
        hideOverlays()
        guard let makeContent else { return }
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, isCapturable: isCapturable)
            let hostingView = NSHostingView(rootView: makeContent(screen))
            hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
            hostingView.setAccessibilityElement(false)
            window.contentView = hostingView
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    deinit {
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
    }
}
