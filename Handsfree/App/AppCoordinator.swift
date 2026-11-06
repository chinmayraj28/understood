//
//  AppCoordinator.swift
//  Handsfree
//
//  The composition root: the one place that loads Settings, creates every part
//  (PartAssembly), connects them, and starts the overlay, the menu bar panel
//  and the voice session. Also runs demo mode. New for Handsfree; it takes the
//  place of Clicky's CompanionManager, which owned Clicky's own voice pipeline.
//
//  How the parts are connected:
//  - Every package posts to ActivityBus.shared; the companion and the panel listen.
//  - Every user sentence goes to the stop watcher, which cancels the task runner on "stop".
//  - The task runner's cancel halts the hands first, so the pointer freezes at once.
//  - The task runner's events are spoken by the voice session.
//  - The voice session gets every package's tools and memory's summary.
//

import AppKit
import Foundation
import HFCore
import os
import SwiftUI

@MainActor
final class AppCoordinator {
    let options: LaunchOptions
    private let bus = ActivityBus.shared
    private let logger = Logger(subsystem: "com.handsfree", category: "app")

    private var settings: HFCore.Settings
    private let companion: CompanionModel
    private let pointer: PointerTracker
    private let appModel: AppModel
    private let overlays = OverlayWindowManager()
    private var panel: MenuBarPanelManager?
    private var parts: AssembledParts?
    private var demoPlayer: DemoPlayer?
    private var demoBackdropWindow: DemoBackdropWindow?
    private var setupRefreshTimer: Timer?
    private var hasStartedVoice = false
    /// Result of the click-through check: nil until it has run.
    private var overlayLetsClicksThrough: Bool?

    init(options: LaunchOptions) {
        self.options = options
        self.settings = HFCore.Settings.load(envFileCandidates: Self.envFileCandidates())
        self.companion = CompanionModel(bus: .shared)
        self.pointer = PointerTracker(mode: options.isDemo ? .simulated : .realPointer)
        self.appModel = AppModel(setupFacts: Self.currentSetupFacts(settings: settings))
        appModel.isDemo = options.isDemo
    }

    func start() {
        logger.notice("Handsfree starting. Demo: \(self.options.isDemo, privacy: .public)")
        companion.start()
        pointer.start()
        showOverlays()
        panel = MenuBarPanelManager(isCapturable: options.overlayIsCapturable, makePanelContent: { [unowned self] in
            AnyView(PanelView(
                app: appModel, companion: companion,
                onSetupAction: { [weak self] action in self?.perform(action) },
                onPlayDemo: { [weak self] in self?.relaunchInDemoMode() }))
        })

        if options.isDemo {
            startDemo()
        } else {
            connectParts()
        }

        refreshSetup()
        writeStatusFile()
        // Once the overlays are on screen, confirm with the window server that they take no clicks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.checkOverlayLetsClicksThrough() }
        if options.requestsPermissionsAtLaunch { requestAllPermissions() }
        if options.showsPanelAtLaunch || (!options.isDemo && !appModel.isReady) {
            panel?.showPanelSoon()
        }
        startSetupRefresh()

        if let seconds = options.quitAfterSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                NSApp.terminate(nil)
            }
        }
    }

    /// Shuts everything down, then calls `completion` on the main thread.
    /// The quit hooks (stop the runner, halt and release the hands, restore the
    /// web-content switches) run off the main thread, because restoring can take
    /// over a second per app that does not answer. They get at most 4 seconds.
    func shutDown(completion: @escaping () -> Void) {
        demoPlayer?.stop()
        pointer.stop()
        companion.stop()
        overlays.hideOverlays()
        guard let parts else { completion(); return }
        let quitHooks = parts.quitHooks
        let voice = parts.voice
        let hooksFinished = DispatchGroup()
        hooksFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for hook in quitHooks { hook() }
            hooksFinished.leave()
        }
        Task { @MainActor in
            await voice.stop()
            let deadline = DispatchTime.now() + 4
            DispatchQueue.global().async {
                let result = hooksFinished.wait(timeout: deadline)
                DispatchQueue.main.async {
                    if result == .timedOut { self.logger.error("Quit hooks did not finish within 4 s; quitting anyway.") }
                    completion()
                }
            }
        }
    }

    /// Opening Handsfree again while it runs (double-clicking it in Finder) opens the
    /// panel. That way a helper can always reach it, even when a crowded menu bar
    /// hides the icon behind the MacBook's camera notch.
    func reopened() {
        panel?.showPanel()
    }

    // MARK: - Overlay

    private func showOverlays() {
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        let showsSimulatedPointer = options.isDemo
        overlays.showOverlays(isCapturable: options.overlayIsCapturable) { [companion, pointer] screen in
            AnyView(CompanionOverlayView(
                screenFrame: screen.frame, mainDisplayHeight: mainDisplayHeight,
                showsSimulatedPointer: showsSimulatedPointer, model: companion, pointer: pointer))
        }
    }

    // MARK: - Parts

    /// Creates every part and starts the voice session if the essentials are in place.
    private func connectParts() {
        let assembled = PartAssembly.assemble(settings: settings, bus: bus)
        parts = assembled
        appModel.wiring = assembled.wiring
        for part in assembled.wiring {
            logger.notice("part \(part.part, privacy: .public): \(part.isReal ? "real" : "stand-in", privacy: .public). \(part.note, privacy: .public)")
        }
        Task { await refreshMemorySummary() }
        // Release any key or button a crash may have left held, and switch on web content
        // in Chrome and Electron apps, off the main thread.
        let launchHooks = assembled.launchHooks
        Task.detached(priority: .utility) {
            for hook in launchHooks { await hook() }
        }
        startVoiceIfReady()
    }

    /// The voice session needs the microphone and the ElevenLabs key. Without
    /// them the companion says it is not connected and the panel says why.
    private func startVoiceIfReady() {
        guard !hasStartedVoice, let parts else { return }
        let facts = appModel.setupFacts
        guard facts.microphone == .granted, facts.hasElevenLabsKey else {
            bus.post(.voiceDisconnected(reason: facts.microphone != .granted
                ? "Waiting for the Microphone permission."
                : "Waiting for the ElevenLabs key."))
            return
        }
        hasStartedVoice = true
        let stopWatcher = parts.stopWatcher
        Task {
            let memorySummary = await parts.memory.summaryForPrompt(maxCharacters: 1200)
            await parts.voice.start(tools: parts.tools, memorySummary: memorySummary, onUserSentence: { sentence in
                stopWatcher.hear(sentence)
            })
        }
    }

    private func refreshMemorySummary() async {
        guard let memory = parts?.memory else { return }
        appModel.memorySummary = await memory.summaryForPrompt(maxCharacters: 600)
    }

    // MARK: - Setup

    private static func currentSetupFacts(settings: HFCore.Settings) -> SetupFacts {
        SetupFacts(
            hasElevenLabsKey: !settings.elevenLabsAPIKey.isEmpty,
            hasAnthropicKey: !settings.anthropicAPIKey.isEmpty,
            hasOpenRouterKey: !settings.openRouterAPIKey.isEmpty,
            microphone: PermissionChecker.status(of: .microphone),
            accessibility: PermissionChecker.status(of: .accessibility),
            screenRecording: PermissionChecker.status(of: .screenRecording),
            keysFilePath: keysFilePath())
    }

    private func refreshSetup() {
        let facts = Self.currentSetupFacts(settings: settings)
        if facts != appModel.setupFacts {
            appModel.setupFacts = facts
            panel?.refitPanel()
            writeStatusFile()
            if !options.isDemo { startVoiceIfReady() }
        }
    }

    /// Clicky polls permissions every 1.5 s so the panel updates the moment a
    /// grant is made in System Settings. We do the same, every 2 s.
    private func startSetupRefresh() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSetup()
                self?.panel?.refitPanel()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        setupRefreshTimer = timer
    }

    private func perform(_ action: SetupItem.Action) {
        switch action {
        case .askMacOS(let permission): PermissionChecker.request(permission)
        case .openSettings(let permission): PermissionChecker.openSettings(for: permission)
        case .showKeysFile:
            let url = URL(fileURLWithPath: Self.keysFilePath())
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshSetup() }
    }

    /// Shows macOS's own dialogs, one after another, for whatever is not granted yet.
    private func requestAllPermissions() {
        PermissionChecker.request(.microphone)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { PermissionChecker.request(.accessibility) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { PermissionChecker.request(.screenRecording) }
    }

    // MARK: - Keys file

    /// Where the app looks for `.env`: HFCore's usual places, plus the folders
    /// above the app itself, so a development build in <repo>/build/ finds the
    /// repo's `.env` even though apps started by `open` run in `/`.
    private static func envFileCandidates() -> [URL] {
        var candidates = HFCore.Settings.defaultEnvFileCandidates()
        var directory = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<4 {
            candidates.insert(directory.appendingPathComponent(".env"), at: min(1, candidates.count))
            directory.deleteLastPathComponent()
        }
        return candidates
    }

    /// The keys file in use, or where it should go.
    private static func keysFilePath() -> String {
        if let found = envFileCandidates().first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return found.path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/\(HFCore.Settings.applicationSupportFolderName)/.env").path
    }

    // MARK: - Demo

    private func startDemo() {
        appModel.wiring = PartAssembly.demoWiring
        guard let mainScreen = NSScreen.screens.first else { return }
        let backdropModel = DemoBackdropModel()
        if options.showsBackdrop {
            let window = DemoBackdropWindow(screen: mainScreen, model: backdropModel)
            window.orderFrontRegardless()
            demoBackdropWindow = window
        }
        let player = DemoPlayer(
            bus: bus, pointer: pointer, model: companion, backdrop: backdropModel, mainScreen: mainScreen,
            loops: options.loopsDemo, freezeMoment: options.demoFreezeMoment,
            momentLogURL: options.demoMomentLogPath.map { URL(fileURLWithPath: $0) })
        demoPlayer = player
        // Give the overlay a moment to appear before the first event.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { player.play() }
    }

    private func relaunchInDemoMode() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--demo", "--show-panel"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Click-through check

    /// Asks the window server which window a mouse-down would hit at points
    /// spread over every screen. If it is ever one of our overlays, the overlay
    /// would be stealing the user's clicks: that is logged as an error and
    /// recorded in app-status.json. It moves nothing and clicks nothing.
    private func checkOverlayLetsClicksThrough() {
        let overlayNumbers = Set(overlays.windowNumbers)
        guard !overlayNumbers.isEmpty else { return }
        var interceptingPoints: [CGPoint] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            for fractionX in [0.1, 0.5, 0.9] {
                for fractionY in [0.1, 0.5, 0.9] {
                    let point = CGPoint(x: frame.minX + frame.width * fractionX, y: frame.minY + frame.height * fractionY)
                    let hitWindowNumber = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                    if overlayNumbers.contains(hitWindowNumber) { interceptingPoints.append(point) }
                }
            }
        }
        overlayLetsClicksThrough = interceptingPoints.isEmpty
        if interceptingPoints.isEmpty {
            logger.notice("click-through check passed: no overlay window would receive a click at \(NSScreen.screens.count * 9, privacy: .public) points")
        } else {
            logger.error("click-through check FAILED: an overlay would receive clicks at \(interceptingPoints.count, privacy: .public) points")
        }
        writeStatusFile()
    }

    // MARK: - Status file

    /// Writes what the app can see about itself (never a key) to
    /// <data directory>/app-status.json, so scripts and the lead can check
    /// permissions and wiring without opening the panel.
    private func writeStatusFile() {
        let facts = appModel.setupFacts
        func describe(_ status: PermissionStatus) -> String {
            switch status {
            case .granted: return "granted"
            case .notAsked: return "not asked"
            case .notGranted: return "not granted"
            }
        }
        let status: [String: Any] = [
            "written_at": ISO8601DateFormatter().string(from: Date()),
            "bundle_path": Bundle.main.bundlePath,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "demo": options.isDemo,
            "microphone": describe(facts.microphone),
            "accessibility": describe(facts.accessibility),
            "screen_recording": describe(facts.screenRecording),
            "keys_present": [
                "ELEVENLABS_API_KEY": facts.hasElevenLabsKey,
                "ANTHROPIC_API_KEY": facts.hasAnthropicKey,
                "OPENROUTER_API_KEY": facts.hasOpenRouterKey,
            ],
            "linked_packages": RealParts.linkedPackages,
            "overlay_click_through_check": overlayLetsClicksThrough.map { $0 ? "passed" : "FAILED" } ?? "not run yet",
            "parts": appModel.wiring.map { ["part": $0.part, "real": $0.isReal, "note": $0.note] },
        ]
        do {
            try FileManager.default.createDirectory(at: settings.dataDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settings.dataDirectory.appendingPathComponent("app-status.json"), options: .atomic)
        } catch {
            logger.error("Could not write app-status.json: \(error.localizedDescription, privacy: .public)")
        }
        logger.notice("permissions: microphone \(describe(facts.microphone), privacy: .public), accessibility \(describe(facts.accessibility), privacy: .public), screen recording \(describe(facts.screenRecording), privacy: .public)")
    }
}

extension PartAssembly {
    /// What the panel lists in demo mode, where no part runs.
    static var demoWiring: [PartWiring] {
        [PartWiring(part: "Demo script", package: "Handsfree", isReal: false, note: "Demo mode: no network, no permissions, nothing on the Mac is touched.")]
    }
}
