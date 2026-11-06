import CoreGraphics
import Foundation
import HFCore
import Testing
@testable import HFScreenAgent

// The screen agent's loop, with Claude, the hands, the eyes and the labels all faked.

private let sendButton = CGRect(x: 1200, y: 780, width: 150, height: 60)  // screen points
private let sendPoint = CGPoint(x: 1275, y: 810)
private let sendDescription = "Click button \"Send\" in WhatsApp, window \"Amma\""

private func labelsWithSend() -> FakeLabels {
    let labels = FakeLabels()
    labels.add(sendButton, .button, "Send")
    return labels
}

private func clickSend(id: String = UUID().uuidString) -> JSONValue {
    computer("left_click", ["coordinate": pixel(forScreen: sendPoint)], id: id)
}

@Suite struct SafetyBackstopInTheLoop {
    @Test func riskyClickIsHeldUntilConfirmedThenDone() async throws {
        let transport = ScriptedTransport(turns: [turn([clickSend()]), turn([finished("Sent.")])])
        let hands = FakeHands()
        let context = FakeContext()
        let summary = try await makeAgent(transport: transport, hands: hands, labels: labelsWithSend()).run(goal: context.goal, context: context)

        #expect(summary == "Sent.")
        #expect(context.confirms.map(\.description) == [sendDescription])
        #expect(context.actions.first?.target?.role == .button, "the gate gets structured fields, not only a sentence")
        guard case .click(let point, .left, 1, []) = hands.presses.first else { Issue.record("no click"); return }
        #expect(abs(point.x - 1275) < 1 && abs(point.y - 810) < 1, "pixels map back to screen points")
    }

    @Test func thePointerGlidesBeforeTheTargetIsNamed() async throws {
        // WhatsApp's voice-message button becomes Send once text is typed: name what is
        // there when the pointer has arrived, not before.
        let transport = ScriptedTransport(turns: [turn([clickSend()]), turn([finished("Done.")])])
        let hands = FakeHands()
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, hands: hands, labels: labelsWithSend()).run(goal: context.goal, context: context)
        guard case .move(let point) = hands.calls.first else { Issue.record("expected a glide first"); return }
        #expect(abs(point.x - 1275) < 1)
        #expect(hands.calls.count == 2, "glide, then the press")
    }

    /// Seen live: the spot reads "Voice message" until text is typed, then "Send".
    /// The check must use the name read after the pointer arrives.
    @Test func aNameThatChangesAsThePointerArrivesIsTheOneChecked() async throws {
        let transport = ScriptedTransport(turns: [turn([clickSend()]), turn([finished("Stopped.")])])
        let labels = FakeLabels()
        labels.add(sendButton, .button, "Voice message", identifier: "ChatBar_VoiceMessageButton")
        let hands = FakeHands()
        hands.onMove = { _ in
            labels.controls = []
            labels.add(sendButton, .button, "Send", identifier: "ChatBar_SendButton")
        }
        let context = FakeContext()
        context.confirmAnswer = false
        _ = try await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        #expect(context.actions.first?.target?.label == "Send")
        #expect(hands.presses.isEmpty, "held, then declined: not pressed")
    }

    @Test func typingWhereFocusIsNotATextBoxIsRefused() async throws {
        let typeID = "t1"
        let transport = ScriptedTransport(turns: [turn([computer("type", ["text": "Amma"], id: typeID)]), turn([finished("Stopped.")])])
        let hands = FakeHands()
        let labels = FakeLabels()
        labels.focus = UIElementInfo(role: .button, label: "New chat", app: "WhatsApp", window: "WhatsApp", frame: .zero)
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        #expect(hands.presses.isEmpty)
        #expect(resultText(lastResults(transport)[typeID]).contains("not a text box"))
    }

    @Test func declinedClickIsSkippedAndTheModelIsTold() async throws {
        let clickID = "click-1", laterID = "later-1"
        let transport = ScriptedTransport(turns: [
            turn([clickSend(id: clickID), computer("key", ["text": "Return"], id: laterID)]),
            turn([finished("I didn't send it.", success: false)]),
        ])
        let hands = FakeHands()
        let context = FakeContext()
        context.confirmAnswer = false

        await #expect(throws: SpeakableError("I didn't send it.")) {
            _ = try await makeAgent(transport: transport, hands: hands, labels: labelsWithSend()).run(goal: context.goal, context: context)
        }
        #expect(hands.presses.isEmpty, "nothing was clicked or pressed")
        #expect(context.confirms.count == 1, "the later Return was not even attempted")
        let results = lastResults(transport)
        #expect(results[clickID]?["is_error"]?.boolValue == true)
        #expect(resultText(results[clickID]).contains("said no"))
        #expect(results[clickID]?["toolset_name"]?.stringValue == "computer")
        #expect(resultText(results[laterID]).hasPrefix("Not executed"))
    }

    @Test func returnInAMessageFieldIsHeld() async throws {
        let transport = ScriptedTransport(turns: [
            turn([computer("type", ["text": "running late"]), computer("key", ["text": "Return"])]),
            turn([finished("Not sent.")]),
        ])
        let hands = FakeHands()
        let context = FakeContext()
        context.confirmAnswer = false
        _ = try await makeAgent(transport: transport, hands: hands).run(goal: context.goal, context: context)

        #expect(context.confirms.count == 1)
        #expect(context.confirms[0].description == "Press Return in text field \"Type a message\" in WhatsApp, window \"Amma\"")
        #expect(context.confirms[0].spoken == "Send \"running late\" to Amma?")
        #expect(hands.presses == [.type("running late", false)], "typed, but Return was not pressed")
    }

    @Test func eachPressOfARepeatedReturnIsConfirmed() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "Return", "repeat": 3])]), turn([finished("Done.")])])
        let hands = FakeHands()
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, hands: hands).run(goal: context.goal, context: context)
        #expect(context.confirms.count == 3)
        #expect(hands.presses == [.key("return"), .key("return"), .key("return")])
    }

    @Test func spaceOnAFocusedButtonIsChecked() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "space"])]), turn([finished("Done.")])])
        let labels = FakeLabels()
        labels.focus = UIElementInfo(role: .button, label: "Delete chat", app: "WhatsApp", window: "Amma", frame: .zero)
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, labels: labels).run(goal: context.goal, context: context)
        #expect(context.confirms.first?.description == "Press Space in button \"Delete chat\" in WhatsApp, window \"Amma\"")
    }

    @Test func itNeverTypesIntoAPasswordField() async throws {
        let typeID = "t1"
        let transport = ScriptedTransport(turns: [turn([computer("type", ["text": "hunter2"], id: typeID)]), turn([finished("Stopped.", success: false)])])
        let hands = FakeHands()
        let labels = FakeLabels()
        labels.front = (app: "Safari", window: "Sign in")
        labels.focus = UIElementInfo(role: .passwordField, label: "Password", app: "Safari", window: "Sign in", frame: .zero)
        let context = FakeContext()
        // One shared rule (HFCore ProtectedSurfaces): the task stops, and the user is not asked to confirm.
        await #expect(throws: SpeakableError(ProtectedSurfaces.spokenRefusal)) {
            _ = try await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        }
        #expect(hands.presses.isEmpty)
        #expect(context.confirms.isEmpty)
        _ = typeID
    }

    /// Seen on the real Mac: Return in Spotlight was read back as `Send "TextEdit" to Orca?`.
    @Test func returnInASearchFieldIsCheckedButNotReadBackAsASend() async throws {
        let transport = ScriptedTransport(turns: [
            turn([computer("key", ["text": "cmd+space"]), computer("type", ["text": "TextEdit"]), computer("key", ["text": "Return"])]),
            turn([finished("TextEdit is open.")]),
        ])
        let labels = FakeLabels()
        labels.front = (app: "Orca", window: "Orca")
        labels.focus = UIElementInfo(role: .textArea, label: "Terminal", app: "Orca", window: "Orca", frame: .zero)
        let hands = FakeHands()
        hands.onKey = { combo in  // cmd+space opens Spotlight and gives it focus, as on the real Mac
            if combo == "cmd+space" {
                labels.focus = UIElementInfo(role: .searchField, label: "Spotlight Search", app: "Spotlight", window: "Spotlight", frame: .zero)
            }
        }
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        #expect(context.confirms.count == 1)
        #expect(context.confirms[0].description.contains("Spotlight Search"))
        #expect(context.confirms[0].spoken == nil)
    }

    /// WhatsApp's window title is always "WhatsApp", so the recipient comes from prepare_send.
    @Test func theSpokenQuestionNamesTheRecipientFromTheChatHeader() async throws {
        let transport = ScriptedTransport(turns: [
            turn([
                computer("type", ["text": "running late"]),
                tool("prepare_send", ["recipient": "Amma", "expected_name": "Amma"]),
                clickSend(),
            ]),
            turn([finished("Sent.")]),
        ])
        let labels = FakeLabels()
        labels.front = (app: "WhatsApp", window: "WhatsApp")
        labels.focus = UIElementInfo(role: .textArea, label: "Type a message", app: "WhatsApp", window: "WhatsApp", frame: .zero)
        labels.add(sendButton, .button, "", identifier: "ChatBar_SendButton")  // icon-only, as in WhatsApp
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, labels: labels).run(goal: context.goal, context: context)
        #expect(context.confirms.first?.spoken == "Send \"running late\" to Amma?")
    }

    @Test func aWindowTitleThatIsJustTheAppNamesNoOne() async throws {
        let transport = ScriptedTransport(turns: [
            turn([computer("type", ["text": "running late"]), computer("key", ["text": "Return"])]),
            turn([finished("Sent.")]),
        ])
        let labels = FakeLabels()
        labels.front = (app: "WhatsApp", window: "WhatsApp")
        labels.focus = UIElementInfo(role: .textArea, label: "Type a message", app: "WhatsApp", window: "WhatsApp", frame: .zero)
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, labels: labels).run(goal: context.goal, context: context)
        #expect(context.confirms.first?.spoken == "Send \"running late\" in WhatsApp?")
    }

    @Test func theWrongChatBlocksTheSendWithoutAsking() async throws {
        let transport = ScriptedTransport(turns: [
            turn([tool("prepare_send", ["recipient": "Priya Patel", "expected_name": "Priya Shah"], id: "p1"), clickSend(id: "c1")]),
            // Claude tries the click again on its own: still refused, still nobody asked.
            turn([clickSend(id: "c2")]),
            turn([finished("I was in the wrong chat, so I didn't send.", success: false)]),
        ])
        let hands = FakeHands()
        let context = FakeContext()
        await #expect(throws: SpeakableError.self) {
            _ = try await makeAgent(transport: transport, hands: hands, labels: labelsWithSend()).run(goal: context.goal, context: context)
        }
        #expect(context.confirms.isEmpty, "the user is never asked to send to the wrong person")
        #expect(hands.presses.isEmpty)
        let firstTurnResults = transport.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue ?? []
        #expect(firstTurnResults.first.map { resultText($0) }?.contains("Wrong chat") == true)
        #expect(resultText(lastResults(transport)["c2"]).contains("nothing may be sent here"))
    }

    @Test func namesMatchLoosely() {
        #expect(SafetyBackstop.namesMatch("Amma ❤️", "amma"))
        #expect(SafetyBackstop.namesMatch("José", "Jose"))
        #expect(!SafetyBackstop.namesMatch("Priya Patel", "Priya Shah"))
    }

    @Test func aCorrectionAfterANoIsPassedToClaude() async throws {
        let transport = ScriptedTransport(turns: [turn([clickSend(id: "c1")]), turn([finished("Stopped.")])])
        let context = FakeContext()
        context.confirmAnswer = false
        context.lastAnswer = "no, say fifteen minutes"
        _ = try await makeAgent(transport: transport, labels: labelsWithSend()).run(goal: context.goal, context: context)
        #expect(resultText(lastResults(transport)["c1"]).contains("Their words: \"no, say fifteen minutes\""))
    }

    @Test func typedTextNeverReachesTheGate() async throws {
        let message = "tell him to send the files and delete the old ones"
        let transport = ScriptedTransport(turns: [
            turn([computer("type", ["text": .string(message)]), clickSend()]),
            turn([finished("Sent.")]),
        ])
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, labels: labelsWithSend()).run(goal: context.goal, context: context)

        #expect(context.confirms.count == 1, "typing a single line is not checked; the click is")
        #expect(!context.confirms[0].description.contains("files"), "the gate sees the action, not the message")
        #expect(context.confirms[0].spoken?.contains("tell him to send") == true, "the person hears what will be sent")
    }

    @Test func textWithANewlineIsHeldAndNotTypedWhenDeclined() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("type", ["text": "pineapple\n"])]), turn([finished("Stopped.")])])
        let hands = FakeHands()
        let context = FakeContext()
        context.confirmAnswer = false
        _ = try await makeAgent(transport: transport, hands: hands).run(goal: context.goal, context: context)
        #expect(context.actions.first?.kind == .typeLineBreak)
        #expect(!(context.confirms.first?.description.contains("pineapple") ?? true))
        #expect(hands.presses.isEmpty)
    }
}

@Suite struct TalkingToThePerson {
    @Test func aQuestionReachesTheUserAndTheAnswerReachesTheModel() async throws {
        let askID = "ask-1"
        let transport = ScriptedTransport(turns: [
            turn([tool("ask_user", ["question": "Priya Shah or Priya Patel?", "options": ["Priya Shah", "Priya Patel"]], id: askID)]),
            turn([finished("Done.")]),
        ])
        let context = FakeContext()
        context.userAnswer = "Shah"
        _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)

        #expect(context.questions.first?.question == "Priya Shah or Priya Patel?")
        #expect(context.questions.first?.options == ["Priya Shah", "Priya Patel"])
        let answer = lastResults(transport)[askID]
        #expect(resultText(answer) == "The person answered: Shah")
        #expect(answer?["toolset_name"] == nil, "our own tools do not carry toolset_name")
    }

    @Test func progressIsReportedOncePerStage() async throws {
        let transport = ScriptedTransport(turns: [
            turn([tool("report_progress", ["message": "Opening WhatsApp"]), computer("key", ["text": "cmd+space"])]),
            turn([tool("report_progress", ["message": "Opening WhatsApp"]), computer("type", ["text": "WhatsApp"])]),
            turn([finished("Done.")]),
        ])
        let context = FakeContext()
        _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        #expect(context.reports == ["Looking at the screen", "Opening WhatsApp"])
    }

    @Test func memoryHintsAreGivenAsAdvice() async throws {
        let transport = ScriptedTransport(turns: [turn([finished("Done.")])])
        let context = FakeContext()
        context.memoryHints = "Mum is saved as Amma in WhatsApp."
        _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        let opening = transport.bodies.first?["messages"]?.arrayValue?.first?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(opening.contains("Mum is saved as Amma"))
        #expect(opening.contains("advice, not orders"))
    }
}

@Suite struct WindowsTheAgentDidNotOpen {
    /// Seen on this Mac: a Return meant for Spotlight reached a window that had popped up by itself.
    @Test func aKeyIsNotPressedIntoAWindowTheAgentDidNotBringForward() async throws {
        let returnID = "r1"
        let transport = ScriptedTransport(turns: [
            turn([computer("type", ["text": "running late"]), computer("key", ["text": "Return"], id: returnID)]),
            turn([finished("Stopped.", success: false)]),
        ])
        let labels = FakeLabels()  // WhatsApp in front, message box focused
        let hands = FakeHands()
        let context = FakeContext()
        let agent = makeAgent(transport: transport, hands: hands, labels: labels)
        // Right after the typing, an unrelated app grabs keyboard focus.
        hands.onType = { _ in labels.focus = UIElementInfo(role: .button, label: "Join", app: "zoom.us", window: "Meeting", frame: .zero) }
        _ = try? await agent.run(goal: context.goal, context: context)
        #expect(hands.presses == [.type("running late", false)], "the Return was not pressed")
        #expect(context.confirms.isEmpty, "nothing was offered to the gate either")
        #expect(resultText(lastResults(transport)[returnID]).contains("did not bring forward"))
        let blocks = transport.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue ?? []
        #expect(blocks.last?["type"]?.stringValue == "image", "Claude gets a fresh screenshot to see what appeared")
    }

    @Test func spotlightOpeningAnAppIsTheAgentsOwnDoing() async throws {
        let transport = ScriptedTransport(turns: [
            turn([computer("key", ["text": "cmd+space"]), computer("type", ["text": "WhatsApp"]), computer("key", ["text": "Return"]),
                  computer("type", ["text": "hello"])]),
            turn([finished("Typed.")]),
        ])
        let labels = FakeLabels()
        labels.front = (app: "Finder", window: "Desktop")
        labels.focus = UIElementInfo(role: .searchField, label: "Search", app: "Finder", window: "Desktop", frame: .zero)
        let hands = FakeHands()
        hands.onKey = { combo in
            if combo == "cmd+space" {
                labels.focus = UIElementInfo(role: .searchField, label: "Spotlight Search", app: "Spotlight", window: "Spotlight", frame: .zero)
            } else if combo == "return" {
                labels.focus = UIElementInfo(role: .textArea, label: "Compose message", app: "WhatsApp", window: "WhatsApp", frame: .zero)
            }
        }
        let context = FakeContext()
        _ = try await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        #expect(hands.presses == [.key("cmd+space"), .type("WhatsApp", false), .key("return"), .type("hello", false)])
    }

    @Test func typingWaitsForSpotlightAndRefusesIfItNeverOpens() async throws {
        let typeID = "t1"
        let transport = ScriptedTransport(turns: [
            turn([computer("key", ["text": "cmd+space"]), computer("type", ["text": "TextEdit"], id: typeID)]),
            turn([finished("Stopped.", success: false)]),
        ])
        let hands = FakeHands()
        let context = FakeContext()  // focus stays in WhatsApp's message box: Spotlight never opens
        _ = try? await makeAgent(transport: transport, hands: hands).run(goal: context.goal, context: context)
        #expect(hands.presses == [.key("cmd+space")], "TextEdit was not typed into WhatsApp")
        #expect(resultText(lastResults(transport)[typeID]).contains("Spotlight has not taken keyboard focus"))
    }

    @Test func anInstallerInFrontStopsTheTaskBeforeAnything() async throws {
        let transport = ScriptedTransport(turns: [turn([finished("Done.")])])
        let labels = FakeLabels()
        labels.front = (app: "Installer", window: "Install Java 8 Update 511")
        let context = FakeContext()
        await #expect(throws: SpeakableError(ProtectedSurfaces.spokenRefusal)) {
            _ = try await makeAgent(transport: transport, labels: labels).run(goal: context.goal, context: context)
        }
        #expect(transport.requests.isEmpty, "Claude was not even asked")
    }

    @Test func aProtectedWindowTakingFocusMidTaskStopsIt() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "Return"])]), turn([finished("Done.")])])
        let labels = FakeLabels()
        labels.focus = UIElementInfo(role: .button, label: "Install", app: "Java Updater", appBundleIdentifier: "com.oracle.java.Java-Updater",
                                     window: "Java Update", frame: .zero)
        let hands = FakeHands()
        let context = FakeContext()
        await #expect(throws: SpeakableError(ProtectedSurfaces.spokenRefusal)) {
            _ = try await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        }
        #expect(hands.presses.isEmpty)
    }

    @Test func anUpdaterTakingTheFrontBetweenTwoPressesStopsTheSecond() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "Down", "repeat": 2])]), turn([finished("Done.")])])
        let labels = FakeLabels()
        let hands = FakeHands()
        hands.onKey = { _ in  // after the first press, the Java updater pops up and takes focus
            labels.front = (app: "Java Updater", window: "Java Update")
            labels.focus = UIElementInfo(role: .button, label: "Install", app: "Java Updater",
                                         appBundleIdentifier: "com.oracle.java.Java-Updater", window: "Java Update", frame: .zero)
        }
        let context = FakeContext()
        await #expect(throws: SpeakableError(ProtectedSurfaces.spokenRefusal)) {
            _ = try await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        }
        #expect(hands.presses == [.key("down")], "the second press was not made")
        #expect(context.confirms.isEmpty)
    }

    @Test func aClickWhoseTargetIsInTheInstallerIsNotMade() async throws {
        let transport = ScriptedTransport(turns: [turn([clickSend()]), turn([finished("Done.")])])
        let labels = FakeLabels()
        labels.add(sendButton, .button, "Install", app: "Installer", window: "Install Java 8 Update 511")
        let hands = FakeHands()
        let context = FakeContext()
        await #expect(throws: SpeakableError(ProtectedSurfaces.spokenRefusal)) {
            _ = try await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        }
        #expect(hands.calls.isEmpty, "not even the glide: the target is checked before the pointer moves")
        #expect(context.confirms.isEmpty, "a yes must not be able to agree to an install")
    }

    @Test func ourOwnOverlayIsNeverClicked() async throws {
        let clickID = "c1"
        let transport = ScriptedTransport(turns: [turn([clickSend(id: clickID)]), turn([finished("Stopped.", success: false)])])
        let labels = FakeLabels()
        labels.add(sendButton, .group, "Chats", app: "Handsfree", window: "Overlay")
        let hands = FakeHands()
        let context = FakeContext()
        _ = try? await makeAgent(transport: transport, hands: hands, labels: labels).run(goal: context.goal, context: context)
        #expect(hands.presses.isEmpty)
        #expect(context.confirms.isEmpty)
        #expect(resultText(lastResults(transport)[clickID]).contains("can't see what is really under the pointer"))
    }

    @Test func aNumberIsSpokenInGroupsAndANameAsItIs() async throws {
        #expect(Speech.recipient("\u{202A}+44 7700 900123\u{202C}") == "+44 7700 900 123")
        #expect(Speech.recipient("Amma") == "Amma")
        let transport = ScriptedTransport(turns: [
            turn([
                computer("type", ["text": "running late"]),
                tool("prepare_send", ["recipient": "\u{202A}+44 7700 900123\u{202C}", "expected_name": "07700 900123"]),
                computer("key", ["text": "Return"]),
            ]),
            turn([finished("Stopped.")]),
        ])
        let labels = FakeLabels()
        labels.front = (app: "WhatsApp", window: "WhatsApp")
        labels.focus = UIElementInfo(role: .textArea, label: "Compose message", app: "WhatsApp", window: "WhatsApp", frame: .zero)
        let context = FakeContext()
        context.confirmAnswer = false
        _ = try await makeAgent(transport: transport, labels: labels).run(goal: context.goal, context: context)
        #expect(context.confirms.first?.spoken == "Send \"running late\" to +44 7700 900 123?")
    }

    @Test func phoneNumbersMatchByDigits() {
        #expect(SafetyBackstop.namesMatch("+44 7700 900123", "07700 900123"))
        #expect(SafetyBackstop.namesMatch("\u{202A}+44 7700 900123\u{202C}", "447700900123"))
        #expect(!SafetyBackstop.namesMatch("+44 7700 900123", "+44 7700 900124"))
    }
}

@Suite struct OnlyTaskFinishedIsSuccess {
    private func textReply(_ text: String, stopReason: String = "end_turn") -> JSONValue {
        turn([["type": "text", "text": .string(text)]], stopReason: stopReason)
    }

    @Test func aReplyWithoutAToolIsNudgedThenSucceedsThroughTaskFinished() async throws {
        let transport = ScriptedTransport(turns: [textReply("I think it's done."), turn([finished("TextEdit is open.")])])
        let context = FakeContext()
        let summary = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        #expect(summary == "TextEdit is open.")
        let nudge = transport.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(nudge.contains("task_finished"))
    }

    @Test func twoRepliesWithoutAToolFailWithWhatWasSaid() async throws {
        let transport = ScriptedTransport(turns: [textReply("I couldn't find Priya."), textReply("I couldn't find Priya. Sorry.")])
        let context = FakeContext()
        await #expect(throws: SpeakableError("I couldn't find Priya.")) {
            _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        }
    }

    @Test func aCutOffReplyIsNotCompletion() async throws {
        let transport = ScriptedTransport(turns: [textReply("Next I will", stopReason: "max_tokens"), turn([finished("Done.")])])
        let context = FakeContext()
        #expect(try await makeAgent(transport: transport).run(goal: context.goal, context: context) == "Done.")
        let nudge = transport.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(nudge.contains("cut off"))
    }

    @Test func aPausedTurnIsContinued() async throws {
        let transport = ScriptedTransport(turns: [textReply("", stopReason: "pause_turn"), turn([finished("Done.")])])
        let context = FakeContext()
        #expect(try await makeAgent(transport: transport).run(goal: context.goal, context: context) == "Done.")
    }
}

@Suite struct StepsAndStopping {
    @Test func oneStepPerModelTurn() async throws {
        let transport = ScriptedTransport(turns: [
            turn([computer("key", ["text": "cmd+space"])]),
            turn([computer("type", ["text": "TextEdit"])]),
            turn([finished("TextEdit is open.")]),
        ])
        let context = FakeContext()
        let summary = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        #expect(context.steps == 3)
        #expect(summary == "TextEdit is open.")
    }

    @Test func theStepLimitEndsTheRun() async throws {
        let transport = ScriptedTransport(turns: Array(repeating: turn([computer("scroll", ["scroll_direction": "down", "scroll_amount": 3])]), count: 5))
        let context = FakeContext()
        context.maxSteps = 2
        await #expect(throws: StepLimitReached.self) {
            _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        }
        #expect(transport.requests.count == 2)
    }

    @Test func cancellingWhileThinkingHaltsTheHands() async throws {
        let transport = ScriptedTransport(turns: [turn([finished("Done.")])])
        transport.delaySeconds = 5
        let hands = FakeHands()
        let agent = makeAgent(transport: transport, hands: hands)
        let context = FakeContext()
        let task = Task { try await agent.run(goal: context.goal, context: context) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let cancelled = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(cancelled) < 1)
        #expect(hands.haltCount == 1)
        #expect(hands.resumeCount == 0, "only the task runner releases the hands after a stop")
    }

    @Test func cancellingMidActionFreezesThePointer() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("mouse_move", ["coordinate": [100, 100]])]), turn([finished("Done.")])])
        let hands = FakeHands()
        hands.actionSeconds = 3  // a long glide
        let agent = makeAgent(transport: transport, hands: hands)
        let context = FakeContext()
        let task = Task { try await agent.run(goal: context.goal, context: context) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelled = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(cancelled) < 1)
        #expect(hands.calls.isEmpty, "the glide never completed")
        #expect(hands.haltCount == 1)
    }
}

@Suite struct HoldWhileTheUserSpeaks {
    @Test func noActionStartsWhileTheUserIsSpeakingAndItStartsAfter() async throws {
        let speaking = Flag(true)
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "cmd+space"])]), turn([finished("Done.")])])
        let hands = FakeHands()
        let agent = makeAgent(transport: transport, hands: hands, holdWhile: { speaking.isOn })
        let context = FakeContext()
        let task = Task { try await agent.run(goal: context.goal, context: context) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(hands.calls.isEmpty, "held while the user speaks")
        #expect(context.steps == 1, "holding does not use up steps")
        speaking.set(false)
        _ = try await task.value
        #expect(hands.presses == [.key("cmd+space")])
        #expect(agent.lastRunStats.holdBoundHits == 0)
    }

    @Test func aStopDuringTheHoldUnwindsCleanly() async throws {
        let speaking = Flag(true)
        let transport = ScriptedTransport(turns: [turn([clickSend()]), turn([finished("Done.")])])
        let hands = FakeHands()
        let agent = makeAgent(transport: transport, hands: hands, labels: labelsWithSend(), holdWhile: { speaking.isOn })
        let context = FakeContext()
        let task = Task { try await agent.run(goal: context.goal, context: context) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let cancelled = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(cancelled) < 0.5)
        #expect(hands.calls.isEmpty, "nothing moved, nothing was clicked")
        #expect(context.confirms.isEmpty)
    }

    @Test func theBoundReleasesAStuckHold() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "cmd+space"])]), turn([finished("Done.")])])
        let hands = FakeHands()
        let agent = makeAgent(transport: transport, hands: hands, maxHoldSeconds: 0.3, holdWhile: { true })
        let context = FakeContext()
        let started = Date()
        _ = try await agent.run(goal: context.goal, context: context)
        #expect(hands.presses == [.key("cmd+space")])
        #expect(agent.lastRunStats.holdBoundHits >= 1)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func thinkingAndListeningArePostedOnTheInjectedBus() async throws {
        let bus = ActivityBus()
        let events = bus.events()
        let speaking = Flag(true)
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "cmd+space"])]), turn([finished("Done.")])])
        let agent = makeAgent(transport: transport, maxHoldSeconds: 0.2, holdWhile: { speaking.isOn }, activity: bus)
        let context = FakeContext()
        _ = try await agent.run(goal: context.goal, context: context)
        var captions: [String] = []
        for await event in events {
            if case .thinking(let caption) = event { captions.append(caption) }
            if captions.count == 3 { break }
        }
        #expect(captions == ["Deciding what to do", "Listening", "Deciding what to do"])
    }

    @Test func aStuckSignalCostsOneBoundNotOnePerAction() async throws {
        let transport = ScriptedTransport(turns: [
            turn([computer("key", ["text": "cmd+l"]), computer("key", ["text": "cmd+t"]), computer("key", ["text": "tab"])]),
            turn([finished("Done.")]),
        ])
        let hands = FakeHands()
        let agent = makeAgent(transport: transport, hands: hands, maxHoldSeconds: 0.3, holdWhile: { true })
        let context = FakeContext()
        let started = Date()
        _ = try await agent.run(goal: context.goal, context: context)
        #expect(hands.presses.count == 3)
        #expect(agent.lastRunStats.holdBoundHits == 1)
        #expect(Date().timeIntervalSince(started) < 0.8)
    }

    @Test func nothingIsHeldByDefault() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "cmd+space"])]), turn([finished("Done.")])])
        let agent = makeAgent(transport: transport)
        let context = FakeContext()
        _ = try await agent.run(goal: context.goal, context: context)
        #expect(agent.lastRunStats.actingBreakdown["hold"] == nil)
    }
}

@Suite struct Failures {
    @Test func aRejectedKeyIsASpeakableError() async throws {
        let transport = ScriptedTransport([(401, ["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]])])
        let context = FakeContext()
        await #expect(throws: SpeakableError("Claude rejected my key. Please check the Anthropic key in settings.")) {
            _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        }
    }

    @Test func overloadIsRetriedThenSucceeds() async throws {
        let transport = ScriptedTransport([(529, ["type": "error"]), (200, turn([finished("Done.")]))])
        let context = FakeContext()
        let summary = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        #expect(summary == "Done.")
        #expect(transport.requests.count == 2)
    }

    @Test func noNetworkIsASpeakableError() async throws {
        let transport = ScriptedTransport([])  // every send fails as if offline
        let context = FakeContext()
        await #expect(throws: SpeakableError("I can't reach Claude. Please check the internet connection.")) {
            _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        }
        #expect(transport.requests.count == 3, "first try plus two retries")
    }

    @Test func aHandsFailureIsASpeakableError() async throws {
        struct EventTapFailed: Error {}
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "cmd+space"])])])
        let hands = FakeHands()
        hands.failure = EventTapFailed()
        let context = FakeContext()
        await #expect(throws: SpeakableError("The pointer or keyboard stopped responding, so I stopped.")) {
            _ = try await makeAgent(transport: transport, hands: hands).run(goal: context.goal, context: context)
        }
    }

    @Test func theHandsOwnSentenceIsPassedOn() async throws {
        let secureInput = SpeakableError("I can't type there because a password box has switched on Secure Input.")
        let transport = ScriptedTransport(turns: [turn([computer("type", ["text": "hello"])])])
        let hands = FakeHands()
        hands.failure = secureInput
        let context = FakeContext()
        await #expect(throws: secureInput) {
            _ = try await makeAgent(transport: transport, hands: hands).run(goal: context.goal, context: context)
        }
    }

    @Test func noScreenshotIsASpeakableError() async throws {
        struct CaptureFailed: Error {}
        let eyes = FakeEyes()
        eyes.failure = CaptureFailed()
        let context = FakeContext()
        await #expect(throws: SpeakableError("I couldn't see the screen. Screen Recording permission may be missing.")) {
            _ = try await makeAgent(transport: ScriptedTransport(turns: []), eyes: eyes).run(goal: context.goal, context: context)
        }
    }

    @Test func aRefusalIsASpeakableError() async throws {
        let transport = ScriptedTransport(turns: [turn([], stopReason: "refusal")])
        let context = FakeContext()
        await #expect(throws: SpeakableError.self) {
            _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        }
    }
}

@Suite struct RequestShape {
    @Test func theRequestMatchesTheDocumentedAPI() async throws {
        let transport = ScriptedTransport(turns: [turn([computer("key", ["text": "cmd+space"], id: "k1")]), turn([finished("Done.")])])
        let context = FakeContext()
        _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil, "the toolset needs no beta header")

        let body = try #require(transport.bodies.first)
        let toolset = try #require(body["tools"]?.arrayValue?.first)
        #expect(toolset["type"]?.stringValue == "computer_toolset_20260801")
        #expect(toolset["name"] == nil, "the toolset entry takes no name")
        #expect(toolset["configs"]?["hold_key"]?["enabled"]?.boolValue == false)
        #expect(body["thinking"]?["type"]?.stringValue == "between_tools", "Sonnet 5.5's thinking-off mode")
        #expect(body["output_config"]?["effort"]?.stringValue == "low")
        #expect(body["system"]?.arrayValue?.first?["cache_control"] != nil)

        // The second request carries the key press's result, echoing toolset_name, plus a fresh screenshot.
        let result = try #require(lastResults(transport)["k1"])
        #expect(result["toolset_name"]?.stringValue == "computer")
        #expect(result["content"]?.arrayValue?.contains { $0["type"]?.stringValue == "image" } == true)
        #expect(result["cache_control"] != nil, "the newest turn carries a cache breakpoint")
    }

    /// Seen on the real API: "all content must be type `text` if `is_error` is true".
    @Test func anErrorResultCarriesOnlyTextAndTheScreenFollowsIt() async throws {
        let transport = ScriptedTransport(turns: [
            turn([computer("key", ["text": "cmd+space"], id: "k1"), computer("key", ["text": "Return"], id: "r1")]),
            turn([finished("Stopped.")]),
        ])
        let context = FakeContext()
        context.confirmAnswer = false  // the Return is refused, after cmd+space acted
        _ = try await makeAgent(transport: transport).run(goal: context.goal, context: context)
        let blocks = transport.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue ?? []
        let refused = try #require(blocks.first { $0["tool_use_id"]?.stringValue == "r1" })
        #expect(refused["content"]?.arrayValue?.allSatisfy { $0["type"]?.stringValue == "text" } == true)
        #expect(blocks.last?["type"]?.stringValue == "image", "the fresh screenshot follows the results")
    }

    @Test func keyNamesAreConvertedForTheHands() {
        #expect(ToolCallParser.handsKeyName("Return") == "return")
        #expect(ToolCallParser.handsKeyName("super+space") == "cmd+space")
        #expect(ToolCallParser.handsKeyName("ctrl+shift+Tab") == "ctrl+shift+tab")
        #expect(ToolCallParser.handsKeyName("cmd+BackSpace") == "cmd+delete")
        #expect(ToolCallParser.handsKeyName("alt+Page_Down") == "option+page_down")
        #expect(ToolCallParser.parseModifiers("super+shift") == [.command, .shift])
    }

    @Test func spokenSummariesAreOneSentence() {
        #expect(Speech.firstSentence("The link is meet.google.com/abc-defg-hij. Then more.") == "The link is meet.google.com/abc-defg-hij.")
        #expect(Speech.firstSentence("  Done  ") == "Done")
    }

    @Test func oldScreenshotsArePrunedInOneBatch() {
        let image: JSONValue = ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "x"]]
        let messages: [JSONValue] = (0..<6).map { _ in ["role": "user", "content": [["type": "tool_result", "tool_use_id": "a", "content": [image]]]] }
        let pruned = MessageEditing.removingImages(from: messages, keepingLast: 3)
        #expect(MessageEditing.imageCount(pruned) == 3)
        #expect(MessageEditing.imageCount(Array(pruned.suffix(3))) == 3, "the newest are kept")
    }

    @Test func theBundledPromptMatchesTheDocsCopy() throws {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/prompts/screen_agent.md")
        let docsText = try String(contentsOf: docs, encoding: .utf8)
        #expect(ScreenAgentConfiguration.bundledSystemPrompt() == docsText,
                "copy docs/prompts/screen_agent.md to Sources/HFScreenAgent/Resources/screen_agent.md")
    }
}

@Suite struct OtherIrreversibleRoutes {
    private func question(_ action: ComputerAction, labels: FakeLabels = FakeLabels()) async -> SafetyQuestion? {
        await SafetyBackstop(labels: labels).question(for: action)
    }

    @Test func dangerousShortcutsAreChecked() async {
        for combo in ["cmd+delete", "cmd+shift+delete", "cmd+return", "cmd+q", "cmd+shift+d", "enter"] {
            #expect(await question(.key(combo: combo, repeatCount: 1)) != nil, "\(combo) must be checked")
        }
    }

    @Test func harmlessShortcutsAreNot() async {
        for combo in ["cmd+space", "cmd+l", "cmd+t", "tab", "escape", "down", "space"] {
            #expect(await question(.key(combo: combo, repeatCount: 1)) == nil, "\(combo) needs no check in a text field")
        }
        #expect(await question(.scroll(dx: 0, dy: 3, point: nil)) == nil)
        #expect(await question(.move(to: .zero)) == nil)
        #expect(await question(.type(text: "running late")) == nil)
    }

    @Test func dragToTheBinIsChecked() async {
        let labels = FakeLabels()
        labels.add(CGRect(x: 0, y: 0, width: 50, height: 50), .listItem, "Taxes.pdf", app: "Finder", window: "Documents")
        labels.add(CGRect(x: 1300, y: 850, width: 60, height: 50), .dockItem, "Bin", app: "Dock", window: "")
        let asked = await question(.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 1320, y: 870)), labels: labels)
        #expect(asked?.action.kind == .drag)
        #expect(asked?.action.description == "Drag list item \"Taxes.pdf\" in Finder, window \"Documents\" to Dock item \"Bin\" in Dock")
    }

    @Test func plainDeleteIsCheckedOnlyOutsideTextFields() async {
        #expect(await question(.key(combo: "delete", repeatCount: 1)) == nil)
        let inList = FakeLabels()
        inList.focus = UIElementInfo(role: .listItem, label: "Inbox", app: "Mail", window: "Inbox", frame: .zero)
        #expect(await question(.key(combo: "delete", repeatCount: 1), labels: inList) != nil)
    }

    @Test func anUnknownTargetIsSaidPlainly() async {
        let asked = await question(.click(button: .left, count: 1, point: CGPoint(x: 5, y: 5), modifiers: []))
        #expect(asked?.action.isTargetUnknown == true)
        #expect(asked?.action.description == "Click an unknown control in WhatsApp, window \"Amma\"")
    }
}

@Suite struct StructuredExtraction {
    @Test func extractUsesStructuredOutputsAndParsesTheJSON() async throws {
        let transport = ScriptedTransport(turns: [
            ["type": "message", "role": "assistant", "stop_reason": "end_turn",
             "content": [["type": "text", "text": "{\"contact\": \"Priya Shah\"}"]]],
        ])
        let client = ClaudeClient(apiKey: "k", structuredModel: "claude-haiku-5-5", transport: transport, retryBaseDelay: 0)
        let schema: JSONValue = ["type": "object", "properties": ["contact": ["type": "string"]], "required": ["contact"]]
        let result = try await client.extract(instructions: "Who?", input: "Shah", schema: schema)
        #expect(result == ["contact": "Priya Shah"])
        let body = try #require(transport.bodies.first)
        #expect(body["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(body["output_config"]?["format"]?["schema"] == schema)
        #expect(body["tool_choice"] == nil, "no forced tool use: Sonnet and Opus 5.5 reject it")
    }

    @Test func aMalformedAnswerThrows() async {
        let transport = ScriptedTransport(turns: [["type": "message", "content": [["type": "text", "text": "not json"]]]])
        let client = ClaudeClient(apiKey: "k", transport: transport, retryBaseDelay: 0)
        await #expect(throws: SpeakableError.self) {
            _ = try await client.extract(instructions: "", input: "", schema: ["type": "object"])
        }
    }
}
