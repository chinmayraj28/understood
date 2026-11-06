//
//  MenuBarPanelManager.swift
//  Handsfree
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT, Farza): MenuBarPanelManager.swift.
//
//  The menu bar icon and the dark panel that drops down below it. Kept from
//  Clicky: an NSStatusItem with a template icon; a borderless, non-activating
//  NSPanel hosting SwiftUI, so opening it does not take focus from the app in
//  front; the panel centred under the icon, 4 points below the menu bar, sized
//  to its content; and closing on a click outside, the way a popover does.
//  Changed: our own icon and panel; the panel opens at launch when setup is
//  incomplete. Nothing in it is needed to use the product: it is for the
//  person helping with setup, and for demos.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let handsfreeDismissPanel = Notification.Name("handsfreeDismissPanel")
}

/// A panel that can become key even though it is non-activating, so its buttons respond on the first click.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissObserver: NSObjectProtocol?
    private let makePanelContent: () -> AnyView
    private let isCapturable: Bool
    private let panelWidth: CGFloat = 372

    init(isCapturable: Bool = false, makePanelContent: @escaping () -> AnyView) {
        self.makePanelContent = makePanelContent
        self.isCapturable = isCapturable
        super.init()
        createStatusItem()
        dismissObserver = NotificationCenter.default.addObserver(forName: .handsfreeDismissPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = BrandMarks.menuBarIcon()
        button.image?.isTemplate = true
        button.setAccessibilityLabel("Handsfree")
        button.toolTip = "Handsfree"
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Opens the panel shortly after launch, once the icon is in the menu bar.
    func showPanelSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        if panel == nil { createPanel() }
        positionPanelBelowStatusItem()
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let hostingView = NSHostingView(rootView: makePanelContent().frame(width: panelWidth))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        menuBarPanel.isFloatingPanel = true
        // Clicky used .floating. We use the menu bar's own level, so the panel also
        // shows above the demo backdrop, which covers the Dock.
        menuBarPanel.level = .statusBar
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        // The panel is not something the screen agent should see or click either.
        menuBarPanel.sharingType = isCapturable ? .readOnly : .none
        menuBarPanel.contentView = hostingView
        panel = menuBarPanel

        // The panel's height follows its content as the transcript and setup list change.
        hostingView.postsFrameChangedNotifications = true
    }

    private func positionPanelBelowStatusItem() {
        guard let panel, let buttonWindow = statusItem?.button?.window else { return }
        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4
        let fittingHeight = panel.contentView?.fittingSize.height ?? 400
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var originX = statusItemFrame.midX - panelWidth / 2
        originX = min(max(originX, screenFrame.minX + 8), screenFrame.maxX - panelWidth - 8)
        let originY = statusItemFrame.minY - fittingHeight - gapBelowMenuBar
        panel.setFrame(NSRect(x: originX, y: originY, width: panelWidth, height: fittingHeight), display: true)
    }

    /// Resizes the open panel to its content, keeping its top edge under the menu bar.
    func refitPanel() {
        guard let panel, panel.isVisible else { return }
        positionPanelBelowStatusItem()
    }

    /// Closes the panel on a click anywhere else, like a popover. Clicky's 0.3 s
    /// delay is kept so a permission dialog opened from the panel does not close it.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if panel.frame.contains(NSEvent.mouseLocation) { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, panel.isVisible else { return }
                    self.hidePanel()
                }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        clickOutsideMonitor = nil
    }
}
