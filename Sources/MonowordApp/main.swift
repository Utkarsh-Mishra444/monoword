import AppKit

#if LOCAL_EXTENSIONS
LocalStartup.run()
#endif
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
