import Foundation

// Waking and sleeping.
//
// The app does not keep a conversation open all the time. While asleep it listens, on the
// Mac itself, for a wake phrase ("Hey Handsfree"). Only when it hears the phrase does it
// open a conversation with ElevenLabs, and it closes that conversation again after a short
// silence. Three reasons:
//
//   1. Cost. ElevenLabs bills by the minute of open conversation. An always-open microphone
//      would use up the minutes whether or not anyone was speaking.
//   2. Privacy. While asleep, no audio leaves the laptop. Earlier tests with an always-open
//      conversation picked up people talking in the room and sent their words to the cloud.
//   3. Other voices. A bystander's sentence can only be acted on while a conversation is open.
//
// It is still hands-free: there is no key to press. That matters, because the people this
// is for cannot press one.

public enum WakeMode: String, Sendable {
    /// Sleep until the wake phrase is heard.
    case phrase
    /// Keep a conversation open the whole time. For demos and testing.
    case always
}

/// Listens on the Mac for the wake phrase. Implemented by HFWake.
///
/// The audio it hears must never leave the laptop: recognition runs on the device.
public protocol WakeListening: AnyObject, Sendable {
    /// Starts listening. `onWake` is called once, the first time the phrase is heard, with
    /// whatever the user said after it in the same breath ("open Spotify"), or an empty string
    /// when they said only the phrase. The listener then stays quiet until the caller calls
    /// `stop()` and `start()` again, which it does when the conversation ends. The rest of the
    /// sentence is handed to the conversation as its first message, so "Hey Handsfree, open
    /// Spotify" works in one go.
    ///
    /// Throws a `SpeakableError` when it cannot listen (no microphone or speech permission,
    /// no on-device recognition for the language).
    func start(onWake: @escaping @Sendable (_ restOfSentence: String) -> Void) async throws

    /// Stops listening and releases the microphone, so the conversation can use it.
    func stop() async

    var isListening: Bool { get }
}
