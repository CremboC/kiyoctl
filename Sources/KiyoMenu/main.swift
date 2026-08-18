import AppKit

let application = NSApplication.shared
let delegate = KiyoMenuController()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
