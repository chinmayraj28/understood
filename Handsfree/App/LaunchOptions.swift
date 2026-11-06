//
//  LaunchOptions.swift
//  Handsfree
//
//  The command-line options the app understands. Everything here is for
//  development, review and recording; the product itself needs no options and
//  no button press. Pure parsing, so it is unit tested.
//

import Foundation

struct LaunchOptions: Equatable {
    /// Play the scripted demo instead of starting the voice session. No network, no permissions.
    var isDemo = false
    /// Repeat the demo until the app quits.
    var loopsDemo = false
    /// Play the demo up to this named moment and hold it still (for screenshots).
    var demoFreezeMoment: String?
    /// Draw a neutral practice backdrop behind the overlay, so a recording shows no private windows.
    var showsBackdrop = false
    /// Let screenshots include the overlay. Only for reviewing the design; the
    /// product keeps the overlay out of every screenshot so the screen agent never sees it.
    var overlayIsCapturable = false
    /// Quit by itself after this many seconds (keeps test runs short).
    var quitAfterSeconds: Double?
    /// Open the menu bar panel at launch.
    var showsPanelAtLaunch = false
    /// Ask macOS for Microphone, Accessibility and Screen Recording at launch.
    var requestsPermissionsAtLaunch = false
    /// Demo only: append each named moment and its time to this file, so a script
    /// can photograph each state as it happens.
    var demoMomentLogPath: String?
    /// Design review: draw the companion's states into PNG files in this folder and quit.
    /// Needs no permission and puts nothing on screen.
    var renderStatesFolder: String?

    /// Unknown arguments are ignored, because macOS adds its own (for example `-NSDocumentRevisionsDebugMode`).
    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        func nextValue() -> String? {
            guard index + 1 < arguments.count else { return nil }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--demo": options.isDemo = true
            case "--loop": options.loopsDemo = true
            case "--freeze":
                options.isDemo = true
                options.demoFreezeMoment = nextValue()
            case "--backdrop": options.showsBackdrop = true
            case "--capturable": options.overlayIsCapturable = true
            case "--quit-after":
                if let value = nextValue(), let seconds = Double(value), seconds > 0 {
                    options.quitAfterSeconds = seconds
                }
            case "--show-panel": options.showsPanelAtLaunch = true
            case "--request-permissions": options.requestsPermissionsAtLaunch = true
            case "--moment-log": options.demoMomentLogPath = nextValue()
            case "--render-states": options.renderStatesFolder = nextValue()
            default: break
            }
            index += 1
        }
        return options
    }
}
