import Foundation

/// Windows the agent must never operate, whatever it was asked: system password and
/// Touch ID prompts, installers, software updaters, "are you sure you want to open
/// this downloaded app" warnings, and password managers.
///
/// Why this exists. On 5 Nov 2026 a test pressed Return to open an app through Spotlight
/// at the moment Oracle's Java updater had popped up by itself. The key reached the
/// updater's default button and an update was installed that nobody asked for. An
/// assistant that presses keys for someone who cannot reach the keyboard must never be
/// the one to agree to an install, approve running downloaded software, or type into a
/// password prompt: those steps need a person's hands.
///
/// The list lives here, in the shared core, so the quick tools, the screen agent and the
/// safety gate all use the same one and cannot drift apart.
///
/// Known limits, said plainly:
/// - An updater that asks from inside an ordinary app's own window (a Sparkle "Install
///   Update" sheet) is not recognised here, because the window belongs to that app. The
///   safety gate's word rules ("install", "update") are the protection in that case.
/// - The Privacy & Security pane belongs to System Settings as a whole, which is not
///   protected, because users legitimately ask for changes there.
public enum ProtectedSurfaces {
    /// Exact bundle identifiers.
    public static let bundleIdentifiers: Set<String> = [
        // System prompts for a password, Touch ID or permission.
        "com.apple.SecurityAgent",  // admin password and authorisation dialogs
        "com.apple.authorizationhost",
        "com.apple.LocalAuthenticationRemoteService",  // Touch ID and password prompts
        "com.apple.LocalAuthentication.UIService",
        "com.apple.UserNotificationCenter",  // system alert and consent dialogs (not notification banners)
        "com.apple.coreservices.uiagent",  // Gatekeeper: "downloaded from the Internet. Are you sure you want to open it?"
        // Installers and updaters.
        "com.apple.installer",
        "com.apple.PackageKit.Install-Assistant",
        "com.apple.SoftwareUpdate",
        "com.apple.SoftwareUpdateNotificationManager",
        "com.apple.MobileSoftwareUpdate.UpdateBrainService",
        "com.oracle.java.Java-Updater",
        "Oracle.MacJREInstaller",
        "org.sparkle-project.Sparkle.Autoupdate",
        "com.microsoft.autoupdate2",
        "com.google.Keystone.Agent",
        "com.google.GoogleUpdater",
        // Where credentials are kept.
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.dashlane.dashlanephonefinal",
        "me.proton.pass.electron",
    ]

    /// Bundle identifier prefixes: every app from these families is protected.
    public static let bundleIdentifierPrefixes: [String] = [
        "com.oracle.java.",
        "Oracle.",
        "org.sparkle-project.",
        "com.apple.InstallAssistant.",  // "Install macOS ..."
    ]

    /// Display names, compared in lower case with invisible marks removed. Used when the bundle
    /// identifier is unknown or unlisted. Names can be translated, so this is a fallback and
    /// deliberately errs toward protecting.
    public static let appNames: Set<String> = [
        "securityagent", "authorizationhost", "coreautha", "coreauthui", "usernotificationcenter",
        "coreservicesuiagent", "universalaccessauthwarn", "installer", "software update",
        "macjreinstaller", "java updater", "autoupdate", "keychain access", "passwords",
    ]

    /// Words that mark an installer or updater when one appears as a whole word in an app's
    /// name or in its bundle identifier: "ZoomInstaller", "com.vendor.installer.helper".
    public static let markerWords: Set<String> = ["installer", "updater", "autoupdate", "uninstaller"]

    public static func isProtected(bundleIdentifier: String, appName: String) -> Bool {
        if !bundleIdentifier.isEmpty {
            if bundleIdentifiers.contains(bundleIdentifier) { return true }
            if bundleIdentifierPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) { return true }
            if !markerWords.isDisjoint(with: ScreenText.words(bundleIdentifier)) { return true }
        }
        // Remove invisible marks (WhatsApp's name starts with one) but keep the original case,
        // because the word splitter needs the capitals to find "Installer" inside "ZoomInstaller".
        let visibleName = String(
            String.UnicodeScalarView(
                appName.unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
                })
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleName.isEmpty else { return false }
        if appNames.contains(visibleName.lowercased()) { return true }
        return !markerWords.isDisjoint(with: ScreenText.words(visibleName))
    }

    /// What to say when one of these is in the way. Short enough to be spoken.
    public static let spokenRefusal =
        "A password or install window has appeared, so I've stopped. That step needs someone's hands."
}
