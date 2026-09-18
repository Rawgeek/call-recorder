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
        //
        // Nothing else is touched. This used to sweep every borderless window of the app, which is
        // not the same set: the window an open menu is drawn in, and the menu bar's own windows,
        // are borderless too. Resizing them and moving them to the top of the screen is what turned
        // the application menu into a strip under the menu bar until the pointer moved away.
        guard let panel = PanelWindow.current else { return }
        fitMenuBarPanel(panel)
        fitAgainAsItSettles(panel)
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
        frame.origin.y = menuBarBottom(of: screen) - frame.height
        guard
            abs(frame.height - window.frame.height) > 0.5
                || abs(frame.origin.y - window.frame.origin.y) > 0.5
        else { return }
        window.setFrame(frame, display: true)
    }

    /// The bottom edge of the menu bar on one screen, in screen coordinates.
    ///
    /// A screen whose menu bar takes room from the desktop answers this with its visible frame. A
    /// screen whose menu bar hides itself reserves nothing, and the same answer would then be the
    /// top of the screen: the panel would be drawn over the bar, which is worse than the gap it was
    /// sent to remove. The row the icon is drawn in is the truth for that case, and the system's own
    /// thickness is the fallback under it.
    static func menuBarBottom(of screen: NSScreen) -> CGFloat {
        let row = MenuBarRow.current
        return menuBarBottom(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            rowBottom: row?.screen === screen ? row?.frame.minY : nil,
            barThickness: NSStatusBar.system.thickness
        )
    }

    /// The same answer, from the numbers alone, so it can be checked without a display.
    static func menuBarBottom(
        frame: CGRect,
        visibleFrame: CGRect,
        rowBottom: CGFloat?,
        barThickness: CGFloat
    ) -> CGFloat {
        // The row the icon is drawn in, when it is known: it is the bar's own bottom edge, on a
        // display whose bar takes room and on one whose bar hides itself alike.
        if let rowBottom, rowBottom > frame.minY, rowBottom < frame.maxY {
            return rowBottom
        }
        let reserved = frame.maxY - visibleFrame.maxY
        guard reserved > 0.5 else {
            // A bar that reserves nothing: the top of the screen is not the bottom of the bar, and
            // answering with it would draw the panel over the menu bar.
            return frame.maxY - barThickness
        }
        return visibleFrame.maxY
    }

    /// Fits the panel again a few times as it appears.
    ///
    /// The system places its own window while it comes on screen, and that placement can land after
    /// the fit made when the window was first seen: the panel then sits a strip lower than the menu
    /// bar for as long as it is open. Two more corrections over the next half second leave it where
    /// the last word put it.
    static func fitAgainAsItSettles(_ window: NSWindow) {
        for delay in [0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                MainActor.assumeIsolated {
                    guard let window, window.isVisible else { return }
                    fitMenuBarPanel(window)
                }
            }
        }
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
