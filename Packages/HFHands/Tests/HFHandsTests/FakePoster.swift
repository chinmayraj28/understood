import CoreGraphics
import Foundation
import HFCore
@testable import HFHands

/// The tests use the package's public recorder, the same one other packages use.
typealias FakePoster = RecordingEventPoster

/// A French AZERTY layout for the letters that matter: A and Q swapped versus US.
struct AzertyLayout: KeyboardLayout {
    private func swap(_ character: Character) -> Character? {
        switch character {
        case "a": return "q"
        case "q": return "a"
        case "A": return "Q"
        case "Q": return "A"
        default: return nil
        }
    }

    func key(for character: Character) -> (code: CGKeyCode, needsShift: Bool)? {
        USKeyboardLayout().key(for: swap(Character(character.lowercased())) ?? character)
    }

    func typingKey(for character: Character) -> (code: CGKeyCode, needsShift: Bool)? {
        USKeyboardLayout().typingKey(for: swap(character) ?? character)
    }
}

/// Real SystemHands on a recording poster, with short pauses so tests are quick.
func makeHands(_ poster: FakePoster, layout: KeyboardLayout = USKeyboardLayout(), activity: ActivityBus = ActivityBus()) -> SystemHands {
    let hands = SystemHands(poster: poster, layout: layout, activity: activity)
    hands.typingInterval = 0.001
    hands.clickHoldInterval = 0.001
    hands.multiClickInterval = 0.001
    hands.dragHoldInterval = 0.001
    hands.scrollInterval = 0.001
    hands.hardwareKeySettle = 0
    return hands
}

/// Collects activity events posted while `body` runs.
func activity(of bus: ActivityBus, during body: () async throws -> Void) async rethrows -> [ActivityEvent] {
    let stream = bus.events()
    try await body()
    bus.post(.listening)  // a marker, so we know where to stop reading
    var events: [ActivityEvent] = []
    for await event in stream {
        if event == .listening { break }
        events.append(event)
    }
    return events
}
