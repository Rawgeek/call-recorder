import AppKit

@MainActor
enum WindowPresentation {
    private static var observesWindows = false

    /// A menu bar accessory app is not the active application, so any window it opens stays
    /// behind whatever the user is working in. Promote to a regular app while visible windows
    /// exist, then return to an accessory once the last one closes.
    ///
    /// The promotion watches every window, so windows opened from the app menu, the Window menu,
    /// or SwiftUI itself come forward too, not just the ones opened from the menu bar popover.
    static func startObservingWindows() {
        guard !observesWindows else { return }
        observesWindows = true
        let center = NotificationCenter.default
        // Becoming key means a real window is in use, so it is what promotes the app. A window the
        // app opens itself never has to wait for this: present() promotes before it opens, because
        // a window created while the app is in the background can appear without ever becoming key.
        // This observer is the net for the other routes, such as the Window menu.
        center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard hasPresentableWindows() else { return }
                applyActivationPolicy(hasVisibleWindows: true)
            }
        }
        center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { refreshActivationPolicySoon() }
        }
    }

    static func present(
        open: () -> Void,
        activate: () -> Void = { Self.bringForward() },
        promote: () -> Void = { applyActivationPolicy(hasVisibleWindows: true) }
    ) {
        promote()
        activate()
        open()
        activate()
        // SwiftUI creates the window after this call returns, and a window opened while the app
        // is in the background is not raised automatically, so order it front once it exists.
        DispatchQueue.main.async {
            bringForward()
            for window in NSApplication.shared.windows
            where keepsAppPromoted(styleMask: window.styleMask, isVisible: window.isVisible) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        refreshActivationPolicySoon()
    }

    static func activationPolicy(hasVisibleWindows: Bool) -> NSApplication.ActivationPolicy {
        hasVisibleWindows ? .regular : .accessory
    }

    static func applyActivationPolicy(hasVisibleWindows: Bool) {
        _ = NSApplication.shared.setActivationPolicy(activationPolicy(hasVisibleWindows: hasVisibleWindows))
    }

    static func bringForward() {
        NSApplication.shared.activate()
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    /// Counts only titled windows. The menu bar popover is borderless, so it never keeps the app
    /// promoted after the user closes it.
    static func hasPresentableWindows() -> Bool {
        presentationCounts(NSApplication.shared.windows)
    }

    static func presentationCounts(_ windows: [NSWindow]) -> Bool {
        windows.contains { keepsAppPromoted(styleMask: $0.styleMask, isVisible: $0.isVisible) }
    }

    /// The menu bar popover is borderless and must not keep the app promoted. Only a real,
    /// visible window counts.
    static func keepsAppPromoted(styleMask: NSWindow.StyleMask, isVisible: Bool) -> Bool {
        isVisible && styleMask.contains(.titled)
    }

    private static func refreshActivationPolicySoon() {
        DispatchQueue.main.async {
            applyActivationPolicy(hasVisibleWindows: hasPresentableWindows())
        }
    }
}
