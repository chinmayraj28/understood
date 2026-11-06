//
//  MenuBarPanelManager.swift
//  Handsfree
//
//  Adapted from Clicky (github.com/farzaa/clicky, MIT, Farza): MenuBarPanelManager.swift.
//
//  The menu bar icon and the panel that drops down below it. Kept from
//  Clicky: an NSStatusItem with a template icon; a borderless, non-activating
//  NSPanel hosting SwiftUI, so opening it does not take focus from the app in
//  front; the panel centred under the icon, 4 points below the menu bar, sized
//  to its content; and closing on a click outside, the way a popover does.
//  Changed: our own icon and panel; the panel opens at launch when setup is
//  incomplete; and (6 Nov) the panel sits on the system's own translucent
//  material with rounded corners and the system shadow, instead of drawing a
//  dark card itself, so it follows light and dark mode and honours Reduce
//  Transparency. Its height follows its content, up to what the screen allows,
//  and Escape closes it.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let handsfreeDismissPanel = Notification.Name("handsfreeDismissPanel")
}

/// A panel that can become key even though it is non-activating, so its buttons respond on the first
/// click. Escape reaches `cancelOperation` through the responder chain whatever has focus inside it.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: .handsfreeDismissPanel, object: nil)
    }
}

/// Reports the content's own height whenever it changes, so the window can follow it.
private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// How tall the panel's body may grow on the current screen, worked out each time the panel opens.
@MainActor
private final class PanelLimits: ObservableObject {
    @Published var bodyMaxHeight = DS.Panel.bodyMaxHeight
}

/// Passes the current limit into the panel's views.
private struct PanelLimitsReader<Content: View>: View {
    @ObservedObject var limits: PanelLimits
    let content: Content

    var body: some View {
        content.environment(\.panelBodyMaxHeight, limits.bodyMaxHeight)
    }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingView: NSView?
    private let limits = PanelLimits()
    private var contentHeight: CGFloat = 0
    private var clickOutsideMonitor: Any?
    private var dismissObserver: NSObjectProtocol?
    private let makePanelContent: () -> AnyView
    private let isCapturable: Bool
    private let panelWidth = DS.Panel.width
    private let gapBelowMenuBar: CGFloat = 4
    /// Kept clear below the panel, so it never runs into the Dock or off the screen.
    private let bottomMargin: CGFloat = 8

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
        updateLimits()
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
        let content = PanelLimitsReader(limits: limits, content: makePanelContent())
            .frame(width: panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
            })
            .onPreferenceChange(PanelHeightKey.self) { [weak self] height in
                // After this layout pass, not inside it: resizing the window re-lays out this same view.
                DispatchQueue.main.async { self?.contentHeightChanged(to: height) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        let hostingView = NSHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.autoresizingMask = [.width, .height]

        // The system's own material, as menus and popovers use: translucent, light or dark with the
        // system, and opaque under Reduce Transparency. The mask gives it the panel's rounded corners,
        // and the window shadow follows the mask.
        let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 400))
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.maskImage = Self.roundedMask(radius: DS.Panel.cornerRadius)
        material.autoresizingMask = [.width, .height]
        hostingView.frame = material.bounds
        material.addSubview(hostingView)

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        menuBarPanel.isFloatingPanel = true
        // Clicky used .floating. We use the menu bar's own level, so the panel also
        // shows above the demo backdrop, which covers the Dock.
        menuBarPanel.level = .statusBar
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = true
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        // The panel is not something the screen agent should see or click either.
        menuBarPanel.sharingType = isCapturable ? .readOnly : .none
        menuBarPanel.contentView = material
        menuBarPanel.setAccessibilityLabel("Handsfree")
        panel = menuBarPanel
        self.hostingView = hostingView
    }

    /// The body's scroll limit for the screen the icon is on: everything below the menu bar, less
    /// room for the header and footer (more at larger text sizes) and a margin.
    private func updateLimits() {
        guard let screen = statusItem?.button?.window?.screen ?? NSScreen.main else { return }
        let reservedForHeaderAndFooter = 150 * PanelView.textScale()
        let limit = max(200, min(DS.Panel.bodyMaxHeight, screen.visibleFrame.height - reservedForHeaderAndFooter))
        if abs(limits.bodyMaxHeight - limit) > 0.5 { limits.bodyMaxHeight = limit }
    }

    /// The content's height changed (a new line in the conversation, a step done): follow it, even while
    /// hidden, so the next opening is the right size straight away.
    private func contentHeightChanged(to height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        positionPanelBelowStatusItem()
    }

    private func positionPanelBelowStatusItem() {
        guard let panel, let buttonWindow = statusItem?.button?.window else { return }
        let statusItemFrame = buttonWindow.frame
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let wanted = contentHeight > 0 ? contentHeight : (hostingView?.fittingSize.height ?? 400)
        // Never past the bottom of the screen, whatever the content asks for.
        let room = statusItemFrame.minY - gapBelowMenuBar - screenFrame.minY - bottomMargin
        let height = max(1, min(wanted, room))
        var originX = statusItemFrame.midX - panelWidth / 2
        originX = min(max(originX, screenFrame.minX + 8), screenFrame.maxX - panelWidth - 8)
        let frame = NSRect(x: originX, y: statusItemFrame.minY - height - gapBelowMenuBar, width: panelWidth, height: height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: panel.isVisible)
        panel.invalidateShadow()
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

    /// A stretchable mask for the material with continuous ("squircle") corners, the same shape as
    /// the SwiftUI clip and edge line in PanelRootView. A continuous corner reaches about 1.53 times
    /// the radius along each edge, so the stretchable middle starts beyond that.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let cap = ceil(radius * 1.53)
        let edge = cap * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
            NSColor.black.setFill()
            NSBezierPath(cgPath: shape).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        return image
    }
}
