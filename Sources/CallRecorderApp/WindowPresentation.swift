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

    /// Gives the panel, and any borderless window of the app, the height of what it holds.
    static func fitMenuBarPanels() {
        // The window the probe found is the panel, whatever shape the system gave it.
        if let panel = PanelWindow.current { fitMenuBarPanel(panel) }
        for window in NSApplication.shared.windows where !window.styleMask.contains(.titled) {
            fitMenuBarPanel(window)
        }
    }

    /// Puts a window under the menu bar, and no taller than what it holds.
    ///
    /// The panel's window belongs to the system. It is placed below the bar while it appears, and
    /// it is sized from its content; that size change moves the top edge, because the system keeps
    /// the corner it placed and grows the window from it. Nothing is drawn above the content, and
    /// the window is clear there, so the desktop shows through and the panel reads as though it had
    /// a transparent header. The strip is removed by putting the top edge back under the menu bar
    /// every time the window is moved or resized.
    ///
    /// The measurement is only ever used to make the window shorter. A window drawn by the system
    /// is the authority on how tall it should be, and a number larger than the window would be a
    /// measurement of something else.
    static func fitMenuBarPanel(_ window: NSWindow) {
        // Measuring a hosting view lays it out, and laying it out can size or move the window,
        // which is another change to correct. Without this the measurement calls straight back
        // into the fit and the stack runs out.
        guard !fitting else { return }
        fitting = true
        defer { fitting = false }
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

    /// True while a fit is measuring, so the change that measurement causes does not fit again.
    private static var fitting = false

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

    /// Counts only titled windows, and never the panel.
    ///
    /// The panel's window carries a title bar that is never drawn, so a count that went by the
    /// style mask alone promoted the app to a regular one for as long as the popover was open and
    /// put a Dock icon on screen for it. The panel is named here instead of guessed.
    static func hasPresentableWindows() -> Bool {
        presentationCounts(NSApplication.shared.windows)
    }

    static func presentationCounts(
        _ windows: [NSWindow],
        panel: NSWindow? = PanelWindow.current
    ) -> Bool {
        windows.contains { window in
            window !== panel
                && keepsAppPromoted(styleMask: window.styleMask, isVisible: window.isVisible)
        }
    }

    /// Only a real, visible window counts. The panel is excluded by the caller.
    static func keepsAppPromoted(styleMask: NSWindow.StyleMask, isVisible: Bool) -> Bool {
        isVisible && styleMask.contains(.titled)
    }

    private static func refreshActivationPolicySoon() {
        DispatchQueue.main.async {
            applyActivationPolicy(hasVisibleWindows: hasPresentableWindows())
        }
    }
}
