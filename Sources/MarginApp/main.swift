import AppKit

let application = NSApplication.shared
let applicationDelegate = AppDelegate()

application.setActivationPolicy(.regular)
application.delegate = applicationDelegate
application.run()
