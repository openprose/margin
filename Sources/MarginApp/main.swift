import AppKit

let application = NSApplication.shared
let applicationDelegate = AppDelegate()

// Start without Launch Services activating a remembered remote Space. The
// delegate promotes Margin to a regular Dock app after it has prepared the
// correct current-Space window.
application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
application.run()
