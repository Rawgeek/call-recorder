import AppKit
import SwiftUI

/// The window the menu bar panel is drawn in.
///
/// The panel's window is made by the system, and nothing on the window says it is the panel: it
/// carries a title bar that is never drawn, so it has the same shape as a window a person opened.
/// A rule that guessed from the style mask either missed the panel or caught real windows. What
/// does identify it is the content: the view below is drawn inside the panel, so the window it
/// ends up in is the panel's window.
@MainActor
enum PanelWindow {
    private static weak var window: NSWindow?
    private static var observed: NSWindow?

    /// The panel's window, once the panel has been drawn at least once.
    static var current: NSWindow? { window }

    /// Says which window the panel is drawn in, and keeps it under the menu bar from then on.
    static func report(_ window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        guard let window else { return }
        observe(window)
        WindowPresentation.fitMenuBarPanel(window)
        // The system places its own window while it appears, which can land after this fit.
        WindowPresentation.fitAgainAsItSettles(window)
    }

    /// Fits the panel again after the window is moved or resized.
    ///
    /// The system sizes the panel from its content and moves it while it appears, and both can
    /// happen after the moment the panel is first seen. Each of those is a chance to put the panel
    /// back under the menu bar. A correction that changes nothing returns without setting the
    /// frame, so this cannot loop.
    private static func observe(_ window: NSWindow) {
        guard observed !== window else { return }
        observed = window
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { WindowPresentation.fitMenuBarPanel(window) }
            }
        }
    }
}

/// Finds the window the menu bar panel is drawn in.
///
/// It is placed in the panel's content, so the window it lands in is the panel's window. The view
/// draws nothing and is one point wide.
struct PanelWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            PanelWindow.report(window)
        }
    }
}
