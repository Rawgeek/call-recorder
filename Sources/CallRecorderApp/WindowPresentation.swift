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
        // The menu bar panel is sized by SwiftUI, and it is sized once per surface: a window that
        // has been tall never comes back shorter on its own. Every moment the panel comes on
        // screen is a chance to give it the height of what it actually holds.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { fitMenuBarPanels() }
            }
        }
    }

    /// Gives every borderless window of the app, which is the menu bar panel and nothing else,
    /// the height of what it holds.
    static func fitMenuBarPanels() {
        for window in NSApplication.shared.windows where !window.styleMask.contains(.titled) {
            fitMenuBarPanel(window)
        }
    }

    /// Puts the menu bar panel under the menu bar, and no taller than what it holds.
    ///
    /// The panel is the app's only borderless window. SwiftUI sizes it from the height of the
    /// surface inside it, and that height only ever grows: a list that loses rows, or a card that
    /// is sent away, leaves the window at the tallest height the surface has had. Nothing is drawn
    /// in the leftover strip at the top, and the window is clear there, so the desktop shows
    /// through it and the panel reads as though it had a transparent header. The strip is removed
    /// by giving the window the height its content asks for, and its top edge is put against the
    /// menu bar for the same reason: a panel that hangs lower than the bar reads the same way.
    ///
    /// The measurement is only ever used to make the window shorter. A window drawn by the system
    /// is the authority on how tall it should be, and a number larger than the window would be a
    /// measurement of something else.
    static func fitMenuBarPanel(_ window: NSWindow) {
        guard !window.styleMask.contains(.titled) else { return }
        // The screen it is on, or the main one: a window that has not been placed yet reports no
        // screen of its own, and the menu bar of the main screen is the same answer.
        guard let content = window.contentView, let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        let fitting = content.fittingSize.height
        if fitting > 0, fitting < frame.height - 0.5 { frame.size.height = fitting }
        frame.origin.y = screen.visibleFrame.maxY - frame.height
        guard
            abs(frame.height - window.frame.height) > 0.5
                || abs(frame.origin.y - window.frame.origin.y) > 0.5
        else { return }
        window.setFrame(frame, display: true)
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
