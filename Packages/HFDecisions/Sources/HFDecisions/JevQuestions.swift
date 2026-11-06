import HFCore

/// The exact questions sent to Jev, and the state each one reads.
///
/// Written to TypeSafe's advice: each option's criteria is an object with
/// `what`, `examples` and `not_for`; lookalike cases go into the criteria of the
/// side they would otherwise wrongly land on; there is always an escape option;
/// and our code decides from the probabilities with fixed thresholds
/// (`Thresholds`). docs/spikes/jev.md reproduces these word for word.
public enum JevQuestions {
    // MARK: Utterance: cancel, command, answer or other

    /// State: `{"said": ..., "assistant_is_working": Bool, "assistant_question": String}`.
    /// "answer" maps to `Intent.other`.
    public static let utteranceID = "intent"
    public static let utterance = JevQuestion(
        kind: .choice,
        instructions: "The user is speaking to a voice assistant that controls their computer. Which option best describes what the user means by `said`? Use `assistant_is_working` and `assistant_question` for context.",
        criteria: [
            "cancel": [
                "what": "The user wants the assistant to stop, halt, pause or abandon what it is doing right now.",
                "examples": ["stop", "no wait, don't", "hang on", "never mind", "cancel that", "stop... stop it", "whoa whoa", "that's wrong, stop"],
                "not_for": "Telling the assistant to stop or pause something else, such as music or a video, is a command.",
            ],
            "command": [
                "what": "A new instruction for the computer, including stopping or pausing media or another app.",
                "examples": ["stop the music", "pause the video", "open Spotify", "turn the volume down", "stop the timer"],
                "not_for": "Replying to the assistant's question, even with a verb such as 'yes send it', is an answer.",
            ],
            "answer": [
                "what": "A reply to the question in `assistant_question`: yes, no, a name, a choice, a number.",
                "examples": ["Shah", "yes", "no", "the second one", "yes send it", "no, the other Priya", "make it 3pm"],
                "not_for": "If `assistant_question` is empty there is nothing to answer.",
            ],
            "other": [
                "what": "Chat, thinking aloud, background speech, or anything that fits none of the options.",
                "examples": ["hmm", "okay", "thanks", "I'm talking to my sister"],
            ],
        ])

    /// What `assistant_question` holds when a question is open but its text is not known.
    public static let unknownOpenQuestion = "(waiting for the user's answer)"

    // MARK: Risk: needs confirmation or safe

    /// State: `{"action": ScreenAction.description}`, e.g. `Click button "Send" in WhatsApp, window "WhatsApp"`.
    public static let riskID = "risk"
    public static let risk = JevQuestion(
        kind: .choice,
        instructions: "An assistant that operates the user's computer is about to perform `action`, described from what is really on screen. Judge the action itself. Could it send something to other people, spend money, delete data, or otherwise be hard to undo, so that it needs the user's spoken yes first?",
        criteria: [
            "needs_confirmation": [
                "what": "The action commits something: it sends or posts a message, invitation or file; pays, buys or orders; deletes or moves something to the bin; submits a form; accepts, declines, joins or calls; or confirms a dialog that does one of these. Also a control that cannot be named, in an app or page where sending is possible.",
                "examples": [
                    "Click button \"Send\" in WhatsApp, window \"WhatsApp\"",
                    "Press Return in text area \"Compose message\" in WhatsApp, window \"WhatsApp\"",
                    "Type a line break in text area \"Compose message\" in WhatsApp, window \"WhatsApp\"",
                    "Click button \"Save\" in Google Chrome, window \"Google Calendar - Event details\"",
                    "Click button \"Place your order\" in Google Chrome, window \"Checkout\"",
                    "Click menu item \"Empty Bin…\" in Finder",
                    "Click button \"OK\" in Finder, window \"Are you sure you want to permanently erase these items?\"",
                    "Click an unlabelled button (identifier \"ChatBar_SendButton\") in WhatsApp, window \"WhatsApp\"",
                ],
                "not_for": "Clicking a field to type in it, opening a chat, folder, email, link, tab or menu, or pressing Return in a search field or the address bar is safe. So is clicking a message or a piece of text: judge the control, not what a message says.",
            ],
            "safe": [
                "what": "The action only looks, navigates or prepares: focusing a text field, opening a chat, folder, email, link, tab or menu, scrolling, playing or pausing media, or pressing Return in a search field or the address bar.",
                "examples": [
                    "Click text area \"Compose message\" in WhatsApp, window \"WhatsApp\"",
                    "Press Return in search field \"Search\" in WhatsApp, window \"WhatsApp\"",
                    "Press Return in text field \"Address and search bar\" in Google Chrome, window \"New Tab\"",
                    "Click link \"Inbox\" in Google Chrome, window \"Gmail\"",
                    "Click row \"Amma\" in WhatsApp, window \"WhatsApp\"",
                    "Click button \"Compose\" in Google Chrome, window \"Inbox - Gmail\"",
                    "Click text containing text in WhatsApp, window \"WhatsApp\"",
                ],
                "not_for": "A button that sends, saves for other people, pays, deletes, submits or confirms needs confirmation, even when it is one click.",
            ],
        ])

    // MARK: Answer: yes, no or unclear

    /// State: `{"assistant_asked": "Send 'running late' to Amma?", "user_replied": "yeah go for it"}`.
    public static let answerID = "reply"
    public static let answer = JevQuestion(
        kind: .choice,
        instructions: "The assistant asked the user to confirm an action (`assistant_asked`) and the user replied out loud (`user_replied`). Is the reply a clear yes to exactly that action, a clear no, or unclear?",
        criteria: [
            "yes": [
                "what": "A clear, unconditional agreement to go ahead with exactly what was asked, with nothing changed.",
                "examples": ["yes", "yeah, go for it", "send it", "do it", "that's right", "yes please", "uh... yes", "yep yep"],
                "not_for": "A yes with a change, a condition or a question attached is unclear: 'yes but change the time', 'yes, after you fix the name', 'did you say yes?'. Saying the word yes is not enough.",
            ],
            "no": [
                "what": "A clear refusal, or a request to hold off.",
                "examples": ["no", "don't", "not yet", "cancel that", "no, don't send it", "nope"],
                "not_for": "Asking for a change before going ahead is unclear: 'no, make it Patel instead'.",
            ],
            "unclear": [
                "what": "Anything else: an edit or change of mind, hesitation, a question back, a condition, or something off topic.",
                "examples": ["wait, change the time to four", "make it Patel instead", "hmm", "uh", "which Amma?", "yes but change the time", "did you say yes?", "what's the weather like"],
            ],
        ])
}

/// The fixed numbers our code decides with. Why each sits where it does is in docs/spikes/jev.md.
public enum Thresholds {
    /// p(cancel) needed while a task is working and nobody asked anything. Low,
    /// because a missed stop lets the agent keep clicking; a false stop costs a restart.
    public static let cancelWhileWorking = 0.40
    /// p(cancel) needed while the assistant waits for an answer. High, because the
    /// task is already paused: a false cancel throws it away, a missed one costs nothing.
    public static let cancelWhileAwaiting = 0.80
    /// p(cancel) needed when nothing is running (the stop watcher ignores it then).
    public static let cancelWhileIdle = 0.60
    /// A non-cancel utterance label must be at least this likely, or the fallback decides.
    public static let utteranceLabelMinimum = 0.50
    /// p(safe) needed to act without asking. Anything less, any error, any timeout: ask.
    public static let safe = 0.90
    /// p(yes) needed for a yes, and no veto word may be present. A wrong yes is the worst error.
    public static let yes = 0.95
    /// p(yes) needed when the whole reply is an unmistakable yes phrase ("mm, yes"),
    /// still with no veto word. The phrase and Jev must agree.
    public static let yesForExactPhrase = 0.80
    /// p(no) needed for a no. A wrong no only means the action does not happen.
    public static let no = 0.70
}
