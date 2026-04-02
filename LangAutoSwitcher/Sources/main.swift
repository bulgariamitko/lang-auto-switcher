import Cocoa
import InputMethodKit

// The connection name must match Info.plist → InputMethodConnectionName
let kConnectionName = "LangAutoSwitcher_Connection"

// Create the IMK server — this registers us as an input method
guard let server = IMKServer(name: kConnectionName,
                              bundleIdentifier: Bundle.main.bundleIdentifier!) else {
    NSLog("LangAutoSwitcher: Failed to create IMKServer")
    exit(1)
}

// Keep a strong reference
_ = server

NSLog("LangAutoSwitcher: Input Method started successfully")

// Run the app event loop
NSApplication.shared.run()
