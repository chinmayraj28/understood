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
    /// Asleep, waking and awake: opens the conversation on the wake phrase, closes it when idle.
    private var cycle: (any ListeningCycling)?
    private var hasStartedListening = false
    private var showPanelObserver: NSObjectProtocol?
    /// Set when quitting starts, so a cycle still being started cannot open the microphone during quit.
    private var isShuttingDown = false
    /// The waking and sleeping sounds.
    private let cues = CuePlayer(bus: .shared)
    /// Result of the click-through check: nil until it has run.
    private var overlayLetsClicksThrough: Bool?

    init(options: LaunchOptions) {
        self.options = options
        self.settings = HFCore.Settings.load(envFileCandidates: Self.envFileCandidates())
        self.companion = CompanionModel(bus: .shared)
        self.pointer = PointerTracker(mode: options.isDemo ? .simulated : .realPointer)
        self.appModel = AppModel(setupFacts: Self.currentSetupFacts(settings: settings))
        appModel.isDemo = options.isDemo
        appModel.wakePhrase = settings.wakePhrase
        appModel.sleepAfterIdleSeconds = settings.sleepAfterIdleSeconds
        appModel.isAlwaysOpen = settings.wakeMode == .always && !options.isDemo
        appModel.listening.wakePhrase = settings.wakePhrase
        appModel.listening.alwaysOpen = settings.wakeMode == .always
        appModel.listening.language = AppWakeLanguage.describe(setting: settings.wakeLanguage)
        appModel.listening.alternatives = settings.wakeAlternatives
        appModel.listening.strictness = settings.wakeStrictness.lowercased()
        appModel.listening.sleepAfterIdleSeconds = settings.sleepAfterIdleSeconds
    }

    func start() {
        if let folder = options.renderStatesFolder {
            // Design review only: draw the states to files and quit, touching nothing else.
            let written = StateSnapshots.render(to: URL(fileURLWithPath: folder))
            logger.notice("Rendered \(written.count, privacy: .public) state snapshots to \(folder, privacy: .public)")
            NSApp.terminate(nil)
            return
        }
        logger.notice("Handsfree starting. Demo: \(self.options.isDemo, privacy: .public)")
        companion.start()
        // A script run makes no sound (the user may be asleep in the room): no chimes.
        if options.scriptPath == nil { cues.start() }
        pointer.start()
        showOverlays()
        panel = MenuBarPanelManager(isCapturable: options.overlayIsCapturable, makePanelContent: { [unowned self] in
            AnyView(PanelView(
                app: appModel, companion: companion,
                onSetupAction: { [weak self] action in self?.perform(action) }))
        })
        // A second copy started while this one runs quits at once and asks this one to show its panel.
        showPanelObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(SingleInstance.showPanelNotification), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.showPanel() }
        }

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
            // A run-loop timer, not DispatchQueue.main.asyncAfter: quitting waits for shutdown work
            // that runs on the main queue, and the main queue cannot run it while it is still
            // inside the block that called terminate. That deadlock left the app hanging (6 Nov).
            let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Shuts everything down, then calls `completion` on the main thread.
    /// The quit hooks (stop the runner, halt and release the hands, restore the
    /// web-content switches) run off the main thread, because restoring can take
    /// over a second per app that does not answer. They get at most 4 seconds.
    func shutDown(completion: @escaping () -> Void) {
        isShuttingDown = true
        demoPlayer?.stop()
        pointer.stop()
        companion.stop()
        overlays.hideOverlays()
        guard let parts else { completion(); return }
        let quitHooks = parts.quitHooks
        let voice = parts.voice
        let cycle = self.cycle
        cues.stop()
        let hooksFinished = DispatchGroup()
        hooksFinished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for hook in quitHooks { hook() }
            hooksFinished.leave()
        }
        Task { @MainActor in
            // Stop listening for the phrase first, so nothing wakes a conversation during quit.
            // Both are bounded: a stuck SDK call must never stop the app quitting.
            let stopped = await Self.finishes(within: 3) {
                await cycle?.stop()
                await voice.stop()
            }
            if !stopped { self.logger.error("The listening cycle or the voice session did not stop within 3 s; quitting anyway.") }
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

    /// Runs `work` and returns true if it finished within `seconds`, false if time ran out
    /// first (the work is left to finish on its own). Not a task group: a group would wait for it.
    private static func finishes(within seconds: Double, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let lock = NSLock()
        var answered = false
        func answerOnce(_ value: Bool, _ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock(); defer { lock.unlock() }
            guard !answered else { return }
            answered = true
            continuation.resume(returning: value)
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                await work()
                answerOnce(true, continuation)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                answerOnce(false, continuation)
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
        var scriptAgentID: String?
        if options.scriptPath != nil {
            guard let testAgent = scriptTestAgentID() else { return }
            scriptAgentID = testAgent
            scriptToolLog = ToolCallLog()
        }
        let assembled = PartAssembly.assemble(settings: settings, bus: bus, scriptAgentID: scriptAgentID)
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
        recordCycle(real: Self.usesWakePhrase(settings: settings) || settings.wakeMode == .always,
                    note: "Not started yet: it starts once \(appModel.setupFacts.needsSpeechRecognition ? "the Microphone and Speech Recognition permissions" : "the Microphone permission") and the ElevenLabs key are in place.")
        prepareVoice(parts: assembled)
        if let scriptPath = options.scriptPath {
            startScriptRun(path: scriptPath)
        } else if options.syncOnly {
            logger.notice("--sync-only: the agent is updated and checked; no listening is started.")
        } else {
            startListeningIfReady()
        }
    }

    /// Whether this run listens for the wake phrase: wake mode "phrase" and HFWake linked.
    /// Otherwise a conversation is kept open, as before wake phrases.
    private static func usesWakePhrase(settings: HFCore.Settings) -> Bool {
        settings.wakeMode == .phrase && RealParts.linkedPackages.contains("HFWake")
    }

    /// Starts the listening cycle once the microphone, the ElevenLabs key and (for the wake
    /// phrase) Speech Recognition are in place. Without them the companion says it is not
    /// connected and the panel says why.
    ///
    /// The conversation is not opened here. In wake-phrase mode the app starts asleep, opens a
    /// conversation when it hears the phrase and closes it after a short silence with nothing
    /// going on. In wake mode "always", or without HFWake, one conversation is kept open.
    private func startListeningIfReady() {
        guard !hasStartedListening, !isShuttingDown, options.mayStartRealListening, let parts else { return }
        let facts = appModel.setupFacts
        let needsSpeech = facts.needsSpeechRecognition
        // Permissions may be granted one at a time, in any order: this runs again on every change
        // (the setup refresh, every 2 s), says exactly what is still missing, and starts as soon
        // as nothing is.
        var missing: [String] = []
        if facts.microphone != .granted { missing.append("the Microphone permission") }
        if needsSpeech && facts.speechRecognition != .granted { missing.append("the Speech Recognition permission") }
        if !facts.hasElevenLabsKey { missing.append("the ElevenLabs key") }
        guard missing.isEmpty else {
            let waitingFor = Self.joinedList(missing)
            if appModel.listening.waitingFor != waitingFor {
                appModel.listening.waitingFor = waitingFor
                bus.post(.voiceDisconnected(reason: "Waiting for \(waitingFor)."))
            }
            return
        }
        appModel.listening.waitingFor = nil
        hasStartedListening = true

        let hooks = CycleWiring.hooks(voice: parts.voice, runner: parts.taskRunner, memory: parts.memory)
        let newCycle: any ListeningCycling
        let onListenerEvent: @Sendable (WakeListenerEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.listenerReported(event) }
        }
        if Self.usesWakePhrase(settings: settings),
            let real = RealParts.makeListeningCycle(settings: settings, hooks: hooks, bus: bus, onListenerEvent: onListenerEvent)
        {
            newCycle = real
            recordCycle(real: true, note: "ListeningCycle with the on-device wake listener: asleep until \u{201C}\(settings.wakePhrase)\u{201D}, asleep again after \(Int(settings.sleepAfterIdleSeconds)) s of quiet")
        } else {
            newCycle = AlwaysOpenCycle(hooks: hooks)
            recordCycle(real: settings.wakeMode == .always, note: settings.wakeMode == .always
                ? "WAKE_MODE=always: one conversation kept open"
                : RealParts.missingNote("HFWake") + " The conversation is kept open instead.")
        }
        cycle = newCycle
        // "That's all, thanks" reaches the cycle through the go_to_sleep tool.
        parts.sleepRequests.setHandler { [weak self] in await self?.userAskedToSleep() ?? .notAvailable }
        // A task's news arriving while asleep (rare: a task keeps it awake until its result is said)
        // wakes it with HFWake's wakeNow(), so the user hears it.
        CycleWiring.wakeForNews(voice: parts.voice, cycle: newCycle)

        Task {
            // The voice session was prepared at launch (connectParts), so the agent update is
            // already on its way or done. Quitting may have started meanwhile: then start nothing.
            guard !self.isShuttingDown else { return }
            await newCycle.start()
            // And if quitting started while the cycle was starting, stop it again at once.
            if self.isShuttingDown { await newCycle.stop() }
        }
    }

    /// "A and B", "A, B and C".
    static func joinedList(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// The wake listener did something. Counts only: no words arrive here.
    private func listenerReported(_ event: WakeListenerEvent) {
        appModel.listening.record(event, at: Date())
        if event == .speechWithoutPhrase { companion.heardSpeechWithoutPhrase() }
        Task { await refreshListening() }
    }

    /// Reads where the cycle, the wake listener and the conversation are, for the panel and the
    /// status file. Runs every 2 s with the setup refresh, and after every listener event.
    private func refreshListening() async {
        var status = appModel.listening
        if let cycle {
            status.cycleState = await cycle.currentState()
            status.listenerRunning = cycle.isListenerRunning
            if status.listenerRunning { status.listenerProblem = nil }
        }
        sleepIfTaskEnded(conversationOpen: parts?.voice.conversationActivity.isOpen ?? false)
        // "Usable" means a wake can open a conversation: in step, or only not checkable right now.
        let agentWasUsable = appModel.listening.agent.map { $0.inSync || $0.couldNotCheck }
        if let voice = parts?.voice {
            status.agent = voice.agentStatus
            status.conversationOpen = voice.conversationActivity.isOpen
            status.conversationConnected = voice.isConversationConnected
        }
        guard status != appModel.listening else { return }
        appModel.listening = status
        panel?.refitPanel()
        writeStatusFile()
        // Loud, once per change, and only for a confirmed problem (a check that merely failed is shown
        // amber on the panel, and a wake still opens): the companion shows why; once usable again while
        // asleep, the hint comes back.
        if let agent = status.agent, !options.isDemo {
            let usable = agent.inSync || agent.couldNotCheck
            if usable == agentWasUsable {
                // no change
            } else if !usable {
                bus.post(.voiceDisconnected(reason: agent.problem ?? "Handsfree's voice isn't set up correctly yet. It is trying again."))
            } else if agentWasUsable == false, status.cycleState == "asleep" {
                bus.post(.asleep(wakePhrase: settings.wakePhrase))
            }
        }
    }

    /// A sign-off made while a task was running or waiting for an answer, held until it ends
    /// (SentenceRouting.swift; unit tested).
    private var sleepRequest = SleepRequest()

    /// The agent's go_to_sleep tool. With no task, it sleeps once the agent's short reply is over
    /// (HFWake's requestSleep). With a task running or a question waiting for their yes, it never
    /// sleeps over it: it sleeps as soon as the task ends, and the agent is told so, to say in a few words.
    @discardableResult
    private func userAskedToSleep() async -> SleepAnswer {
        guard let cycle, let parts else { return .notAvailable }
        switch sleepRequest.asked(taskActive: CycleWiring.isTaskActive(parts.taskRunner)) {
        case .sleepWhenTaskEnds:
            logger.notice("Asked to sleep during a task: sleeping as soon as it ends.")
            return .afterTask
        case .sleepNow, .none:
            return await cycle.requestSleep()
        }
    }

    /// A finished sentence of the user's (the stop watcher has already heard it). A sign-off sleeps,
    /// now or once the task ends; anything else takes back an earlier sign-off.
    private func userSaid(_ route: SentenceRoute) async {
        guard let cycle, let parts else { return }
        switch sleepRequest.heard(route, taskActive: CycleWiring.isTaskActive(parts.taskRunner)) {
        case .none:
            return
        case .sleepWhenTaskEnds:
            logger.notice("The user signed off during a task: sleeping as soon as it ends.")
        case .sleepNow:
            _ = await cycle.requestSleep()
        }
    }

    /// Runs with the 2 s refresh: a sign-off made during a task is carried out once it has ended
    /// (its result is still said first: the cycle waits for speech to finish).
    private func sleepIfTaskEnded(conversationOpen: Bool) {
        guard let parts, let cycle else { return }
        guard sleepRequest.taskHasEnded(taskActive: CycleWiring.isTaskActive(parts.taskRunner), conversationOpen: conversationOpen) else { return }
        Task { _ = await cycle.requestSleep() }
    }

    /// Once per launch, whatever the permissions: the tools, memory's summary and the stop watcher go
    /// to the voice session, which updates the agent on ElevenLabs and reads it back. Done before any
    /// permission is granted, so the panel can say whether the agent is in step during setup.
    private func prepareVoice(parts: AssembledParts) {
        let stopWatcher = parts.stopWatcher
        Task {
            let memorySummary = await parts.memory.summaryForPrompt(maxCharacters: 1200)
            guard !self.isShuttingDown else { return }
            // A script run records every tool call (`ToolCallLog`); otherwise the tools are as built.
            let tools = self.scriptToolLog?.wrap(parts.tools) ?? parts.tools
            let wakePhrases = [self.settings.wakePhrase] + self.settings.wakeAlternatives
            parts.voice.prepareConversations(tools: tools, memorySummary: memorySummary, onUserSentence: { sentence in
                // The stop watcher hears every sentence, sign-offs included, at once and before anything
                // else; a sign-off ("stop listening", "that's all") is detected as well, never instead.
                let route = SentenceRouting.route(sentence, wakePhrases: wakePhrases)
                stopWatcher.hear(route.forStopWatcher)
                Task { @MainActor [weak self] in await self?.userSaid(route) }
            })
        }
    }

    // MARK: - Script runs (test only)

    /// Set in a `--script` run: every tool call, with its time.
    private var scriptToolLog: ToolCallLog?

    /// The TEST agent's id from the keys file (ELEVENLABS_TEST_AGENT_ID). A script never runs on
    /// the user's agent: without a test agent, or if it is the user's, it refuses and quits.
    private func scriptTestAgentID() -> String? {
        let text = (try? String(contentsOfFile: Self.keysFilePath(), encoding: .utf8)) ?? ""
        let id = (ProcessInfo.processInfo.environment["ELEVENLABS_TEST_AGENT_ID"]
            ?? HFCore.Settings.parseEnvFile(text)["ELEVENLABS_TEST_AGENT_ID"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id != settings.elevenLabsAgentID else {
            logger.error("--script refused: no ELEVENLABS_TEST_AGENT_ID, or it is the app's own agent. Run an HFVoice live test once to create the test agent.")
            writeScriptReport(["passed": false, "error": "no test agent (ELEVENLABS_TEST_AGENT_ID), or it is the app's own agent"])
            Self.quitSoon()
            return nil
        }
        return id
    }

    /// Builds the same cycle a normal launch does, with a wake listener that never opens the
    /// microphone, runs the script, writes the report and quits. Needs no Microphone permission.
    private func startScriptRun(path: String) {
        guard let parts, let toolLog = scriptToolLog,
            let script = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            writeScriptReport(["passed": false, "error": "could not read the script at \(path)"])
            Self.quitSoon()
            return
        }
        let listener = ScriptWakeListener()
        let hooks = CycleWiring.hooks(voice: parts.voice, runner: parts.taskRunner, memory: parts.memory)
        guard let scriptCycle = RealParts.makeListeningCycle(
            settings: settings, hooks: hooks, bus: bus, onListenerEvent: { _ in }, listener: listener)
        else {
            writeScriptReport(["passed": false, "error": "HFWake is not linked into this build"])
            Self.quitSoon()
            return
        }
        cycle = scriptCycle
        hasStartedListening = true
        recordCycle(real: true, note: "Script run: HFWake's cycle with a script wake listener (no microphone), text conversation on the TEST agent")
        parts.sleepRequests.setHandler { [weak self] in await self?.userAskedToSleep() ?? .notAvailable }
        CycleWiring.wakeForNews(voice: parts.voice, cycle: scriptCycle)
        let run = ScriptRun(
            steps: ScriptRun.parse(script), voice: parts.voice, cycle: scriptCycle, listener: listener, tools: toolLog,
            labels: parts.labels, hands: parts.hands, safetyGate: parts.safetyGate, bus: bus)
        Task {
            await scriptCycle.start()
            let report = await run.run()
            self.writeScriptReport(report)
            self.logger.notice("Script run finished: \((report["passed"] as? Bool) == true ? "passed" : "FAILED", privacy: .public)")
            Self.quitSoon()
        }
    }

    /// Quits from a run-loop timer. Calling `NSApp.terminate` from inside a main-actor task hangs:
    /// quitting waits for shutdown work that needs the main actor, which that task still holds
    /// (seen in the first script run, 6 Nov; the same trap as the old `--quit-after`).
    private static func quitSoon() {
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func writeScriptReport(_ report: [String: Any]) {
        let url = settings.dataDirectory.appendingPathComponent("script-run.json")
        try? FileManager.default.createDirectory(at: settings.dataDirectory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func recordCycle(real: Bool, note: String) {
        let part = PartWiring(part: "Listening cycle", package: "HFWake", isReal: real, note: note)
        appModel.wiring.removeAll { $0.part == part.part }
        appModel.wiring.append(part)
        logger.notice("part Listening cycle: \(real ? "real" : "stand-in", privacy: .public). \(note, privacy: .public)")
        writeStatusFile()
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
            speechRecognition: PermissionChecker.status(of: .speechRecognition),
            // Only when the wake listener says it needs it (the older recogniser); never on macOS 26.
            needsSpeechRecognition: usesWakePhrase(settings: settings) && RealParts.wakeListenerNeedsSpeechRecognition(),
            keysFilePath: keysFilePath())
    }

    private func refreshSetup() {
        let facts = Self.currentSetupFacts(settings: settings)
        if facts != appModel.setupFacts {
            appModel.setupFacts = facts
            panel?.refitPanel()
            writeStatusFile()
            if !options.isDemo { startListeningIfReady() }
        }
    }

    /// Clicky polls permissions every 1.5 s so the panel updates the moment a
    /// grant is made in System Settings. We do the same, every 2 s.
    private func startSetupRefresh() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSetup()
                self?.panel?.refitPanel()
                guard let self, !self.options.isDemo else { return }
                Task { await self.refreshListening() }
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
        var delay = 1.0
        if appModel.setupFacts.needsSpeechRecognition {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { PermissionChecker.request(.speechRecognition) }
            delay += 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { PermissionChecker.request(.accessibility) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.0) { PermissionChecker.request(.screenRecording) }
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
        var status: [String: Any] = [
            "written_at": ISO8601DateFormatter().string(from: Date()),
            "bundle_path": Bundle.main.bundlePath,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "demo": options.isDemo,
            "microphone": describe(facts.microphone),
            "accessibility": describe(facts.accessibility),
            "screen_recording": describe(facts.screenRecording),
            "speech_recognition": facts.needsSpeechRecognition ? describe(facts.speechRecognition) : "not needed (the wake listener uses SpeechAnalyzer, which needs only the Microphone)",
            "wake_mode": settings.wakeMode.rawValue,
            "wake_phrase": settings.wakePhrase,
            "sleep_after_idle_seconds": settings.sleepAfterIdleSeconds,
            "listens_for_wake_phrase": Self.usesWakePhrase(settings: settings),
            "wake_listener_needs_speech_recognition": facts.needsSpeechRecognition,
            "keys_present": [
                "ELEVENLABS_API_KEY": facts.hasElevenLabsKey,
                "ANTHROPIC_API_KEY": facts.hasAnthropicKey,
                "OPENROUTER_API_KEY": facts.hasOpenRouterKey,
            ],
            "linked_packages": RealParts.linkedPackages,
            "overlay_click_through_check": overlayLetsClicksThrough.map { $0 ? "passed" : "FAILED" } ?? "not run yet",
            "parts": appModel.wiring.map { ["part": $0.part, "real": $0.isReal, "note": $0.note] },
        ]
        // Is the wake listener running, is a conversation open, and what has been heard (counts only).
        if !options.isDemo {
            status["listening"] = appModel.listening.statusDictionary(now: Date())
            if let voice = parts?.voice { status["spoken_news"] = voice.spokenNewsCounts }
        }
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
