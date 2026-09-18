import AppKit
import Observation
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
        // A borderless window that is not the panel: the window an open menu is drawn in is one of
        // those, and resizing it is what turned the application menu into a strip.
        let loose = panel(height: 90, contentHeight: 400)
        let looseBefore = loose.frame
        let window = panel(height: 320, contentHeight: 200)
        PanelWindow.report(window)
        defer { PanelWindow.report(nil) }
        WindowPresentation.fitMenuBarPanels()
        #expect(window.frame.height == 200)
        #expect(abs(window.frame.maxY - screen.visibleFrame.maxY) <= 0.5)
        #expect(other.frame == before)
        #expect(loose.frame == looseBefore)
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

    @Test("a menu bar that hides itself is still a menu bar")
    func aHiddenMenuBarStillHasABottom() {
        // The display this was reported on: 1440 points tall, no room reserved for the menu bar
        // because the bar hides itself. Answering with the top of the screen would draw the panel
        // over the bar, and the strip it was sent to remove is the smaller of the two faults.
        let height = WindowPresentation.menuBarBottom(
            frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1440),
            barThickness: 22
        )

        #expect(height == 1418)
    }

    @Test("a display that reserves room for the menu bar keeps its visible frame")
    func aReservedMenuBarIsUsed() {
        let height = WindowPresentation.menuBarBottom(
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
            barThickness: 22
        )

        #expect(height == 1410)
    }

    @Test("the panel is cut to the height it was measured at, not to what its content view says")
    func theMeasuredHeightIsTheOneUsed() {
        // The panel the system makes answers nothing when it is asked how tall its content is: a
        // fitting size of zero was measured on the machine this was reported on. The height comes
        // from the content that draws itself instead, and this is that path with the same silence.
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 40, width: 360, height: 499),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 499))
        PanelWindow.report(window)
        defer { PanelWindow.report(nil) }
        // The silence itself, so the test keeps saying what the real panel does.
        #expect(window.contentView?.fittingSize.height == 0)

        WindowPresentation.fitMenuBarPanels(contentHeight: 472)

        #expect(window.frame.height == 472)
        #expect(abs(window.frame.maxY - WindowPresentation.menuBarBottom(of: screen)) <= 0.5)
    }

    @Test("the panel gives back the height of a notice that goes away")
    func thePanelGivesBackTheHeightOfANotice() async throws {
        // The panel is sized from its content once, and keeps the tallest size it was given. A
        // notice that goes away would leave its room behind as a strip above the content, and
        // nothing about the window changes in that moment: the correction has to come from the
        // content asking to be measured again. This is that path, through a real hosting view.
        guard let screen = NSScreen.main else { return }
        let content = PanelNoticeModel(showsNotice: true)
        let window = panel(height: 320, contentHeight: 200)
        window.contentView = NSHostingView(rootView: GrowingPanelContent(model: content))
        window.contentView?.layoutSubtreeIfNeeded()
        PanelWindow.report(window)
        defer { PanelWindow.report(nil) }
        // The corrections made while the panel appears have run by now, so what is left to see is
        // the content's own change.
        try await Task.sleep(for: .milliseconds(700))
        let tall = window.frame.height
        #expect(tall > 150)

        content.showsNotice = false
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
            if window.frame.height < tall { break }
        }

        // The notice is gone and the panel is the height of what is left, against the menu bar.
        #expect(window.frame.height < tall)
        #expect(abs(window.frame.maxY - WindowPresentation.menuBarBottom(of: screen)) <= 0.5)
    }
}

/// The panel's content in the two shapes a notice makes: with it, and without it.
@MainActor
@Observable
private final class PanelNoticeModel {
    var showsNotice: Bool

    init(showsNotice: Bool) {
        self.showsNotice = showsNotice
    }
}

private struct GrowingPanelContent: View {
    let model: PanelNoticeModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showsNotice {
                Color.clear.frame(height: 80)
            }
            Color.clear.frame(height: 120)
        }
        .frame(width: 360)
        // The wiring the panel has: whatever changes its height asks for the window to be measured.
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
            WindowPresentation.fitMenuBarPanels(contentHeight: height)
        }
    }
}
