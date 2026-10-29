import AppKit

/// Gives Scribe a Dock icon and a place in ⌘Tab while it has a window open.
///
/// Menu bar apps run as "accessory", which is what keeps them out of the Dock —
/// but an accessory app's windows are also missing from ⌘Tab and the Window
/// menu, so switching away from the library left no way back to it except the
/// menu bar. Being a normal app while a window is open, and an accessory again
/// once they are all closed, gets both behaviours.
@MainActor
enum WindowPresence {

    private static var observers: [NSObjectProtocol] = []

    static func begin() {
        guard observers.isEmpty else { return }
        for name: Notification.Name in [NSWindow.didBecomeKeyNotification,
                                        NSWindow.willCloseNotification,
                                        NSWindow.didChangeOcclusionStateNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name,
                                                                  object: nil,
                                                                  queue: .main) { _ in
                // willClose arrives while the window is still listed, so settle
                // first and then count what is actually left.
                DispatchQueue.main.async { update() }
            }
            observers.append(observer)
        }
        update()
    }

    static func update() {
        // Only real windows count. The menu bar popover is also an NSWindow and
        // must not drag the app into the Dock every time it is opened.
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }

        NSApp.setActivationPolicy(wanted)
        Log.info("activation policy is now \(wanted == .regular ? "regular" : "accessory")")
        if wanted == .regular {
            // Becoming a regular app mid-flight does not raise the window on
            // its own.
            NSApp.activate()
        }
    }
}
