import Cocoa
import InputMethodKit
import Sparkle

// The connection name must match Info.plist → InputMethodConnectionName
let kConnectionName = "LangAutoSwitcher_Connection"

// Create the IMK server — this registers us as an input method
guard let server = IMKServer(name: kConnectionName,
                              bundleIdentifier: Bundle.main.bundleIdentifier!) else {
    NSLog("LangAutoSwitcher: Failed to create IMKServer")
    exit(1)
}
_ = server

// Load the user's keymap.json (or create with defaults) and push any
// overrides into the Rust core before any keystrokes arrive.
KeymapManager.loadAndApply()

// Warm the shared detector off the main thread: dictionary parsing
// (~468k words) happens once per process now, and doing it here means the
// first keystroke doesn't pay for it. `static let` makes this thread-safe.
DispatchQueue.global(qos: .userInitiated).async {
    _ = LanguageDetector.shared
}

// Sparkle auto-update.
//
// Input Method quirk: macOS owns our process lifecycle — when the user types
// it spawns/respawns us. Sparkle's default flow quits the app, replaces the
// .app bundle, and tries to relaunch. The quit + replace work fine, but the
// relaunch attempt is ignored by macOS for input methods. That's intentional:
// the next keystroke spawns the new bundle automatically.
final class UpdateDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Explicit feed URL so SUFeedURL in Info.plist isn't strictly required
        // for testing; keeps the source of truth visible.
        return "https://bulgariamitko.github.io/lang-auto-switcher/appcast.xml"
    }
}
let updateDelegate = UpdateDelegate()
let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: updateDelegate,
    userDriverDelegate: updateDelegate
)
_ = updaterController

NSLog("LangAutoSwitcher: Input Method started successfully (v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))")

// Run the app event loop
NSApplication.shared.run()
