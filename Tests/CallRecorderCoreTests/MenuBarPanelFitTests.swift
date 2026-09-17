import AppKit
import SwiftUI
import Testing
@testable import CallRecorderApp

/// The menu bar panel is given the height of what it holds.
///
/// The panel window is the one surface in the app that the system draws and the app cannot click
/// on from a test. What can be checked is the correction itself: a borderless window taller than
/// its content comes out the height of its content, with its top edge under the menu bar.
@Suite("Menu bar panel fit")
@MainActor
struct MenuBarPanelFitTests {
    private func panel(height: CGFloat, contentHeight: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 40, width: 360, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: Color.clear.frame(width: 360, height: contentHeight)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// The panel as the system makes it, as far as it can be seen from outside: a titled window
    /// whose title bar is never drawn, holding the content.
    private func titledPanel(height: CGFloat, contentHeight: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 40, width: 360, height: height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(
            rootView: Color.clear.frame(width: 360, height: contentHeight)
        )
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @Test("a window taller than its content is cut down to the content")
    func aTallerWindowIsCutDown() {
        // Given a panel that kept the height of a longer list, with a 200-point surface in it.
        let window = panel(height: 320, contentHeight: 200)

        // When
        WindowPresentation.fitMenuBarPanel(window)

        // Then the strip above the content is gone: the window is the height of what it holds.
        #expect(window.frame.height == 200)
    }

    @Test("the panel is put against the menu bar")
    func thePanelIsPutAgainstTheMenuBar() {
        let window = panel(height: 320, contentHeight: 200)
        WindowPresentation.fitMenuBarPanel(window)
        // A window that has never been on screen reports no screen. The main one answers the same
        // question, and a machine with no display at all has no menu bar to sit under.
        guard let screen = window.screen ?? NSScreen.main else { return }
        #expect(abs(window.frame.maxY - screen.visibleFrame.maxY) <= 0.5)
        #expect(abs(window.frame.minY - (screen.visibleFrame.maxY - 200)) <= 0.5)
    }

    @Test("a window that is already the right size where it belongs is left alone")
    func aCorrectPanelIsLeftAlone() {
        guard let screen = NSScreen.main else { return }
        let window = panel(height: 200, contentHeight: 200)
        window.setFrameOrigin(
            NSPoint(x: window.frame.origin.x, y: screen.visibleFrame.maxY - 200)
        )
        let before = window.frame
        WindowPresentation.fitMenuBarPanel(window)
        #expect(window.frame == before)
    }

    @Test("a titled panel with its title bar hidden is still put under the menu bar")
    func aTitledPanelIsFitted() {
        // The panel the system makes carries a title bar that is never drawn, so a rule that went
        // by the style mask missed the one window that needed the fit and left the strip in place.
        guard let screen = NSScreen.main else { return }
        let window = titledPanel(height: 320, contentHeight: 200)
        PanelWindow.report(window)
        defer { PanelWindow.report(nil) }
        #expect(abs(window.frame.maxY - screen.visibleFrame.maxY) <= 0.5)
    }

    @Test("the panel goes back under the menu bar when the system resizes it")
    func thePanelGoesBackUnderTheMenuBarAfterAResize() throws {
        guard let screen = NSScreen.main else { return }
        let window = panel(height: 320, contentHeight: 200)
        PanelWindow.report(window)
        defer { PanelWindow.report(nil) }
        #expect(abs(window.frame.maxY - screen.visibleFrame.maxY) <= 0.5)

        // The system keeps the corner it placed and grows the window from there, which is what
        // moves the top edge down the screen: a row arrives, and the window gets taller while its
        // bottom stays where it was. The resize is what has to put the panel back.
        let placed = window.frame
        window.setFrame(
            NSRect(
                x: placed.origin.x,
                y: placed.origin.y,
                width: placed.width,
                height: placed.height + 80
            ),
            display: false
        )
        #expect(abs(window.frame.maxY - screen.visibleFrame.maxY) <= 0.5)
        #expect(window.frame.height == 200)
    }

    @Test("the sweep fits the panel and leaves a titled window that is not the panel alone")
    func theSweepTouchesOnlyThePanel() {
        guard let screen = NSScreen.main else { return }
        let other = titledPanel(height: 320, contentHeight: 200)
        let before = other.frame
        let window = panel(height: 320, contentHeight: 200)
        PanelWindow.report(window)
        defer { PanelWindow.report(nil) }
        WindowPresentation.fitMenuBarPanels()
        #expect(window.frame.height == 200)
        #expect(abs(window.frame.maxY - screen.visibleFrame.maxY) <= 0.5)
        #expect(other.frame == before)
    }

    @Test("a panel shorter than its content is placed, never grown")
    func aShortPanelIsNotGrown() {
        let window = panel(height: 120, contentHeight: 400)
        PanelWindow.report(window)
        defer { PanelWindow.report(nil) }
        #expect(window.frame.height == 120)
        guard let screen = window.screen ?? NSScreen.main else { return }
        #expect(abs(window.frame.maxY - screen.visibleFrame.maxY) <= 0.5)
    }
}
