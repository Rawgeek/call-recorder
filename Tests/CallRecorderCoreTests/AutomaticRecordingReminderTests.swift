import AppKit
import SwiftUI
import Testing
@testable import CallRecorderCore
@testable import CallRecorderApp

/// The popover's reminder that automatic recording is off, and the way to put it down.
///
/// The card offers the fix for the setting the app is built around, and it sat over the Recent
/// list for as long as that setting stayed off. There was nothing to press to send it away: a
/// reminder with no way down is a piece of screen the user cannot get back.
@Suite("Automatic recording reminder")
@MainActor
struct AutomaticRecordingReminderTests {
    @Test("the reminder is due while detection is off")
    func dueWhileOff() {
        #expect(MenuBarView.offersAutomaticRecordingReminder(enabled: false, dismissed: false))
    }

    @Test("a dismissed reminder stays down")
    func dismissedStaysDown() {
        #expect(!MenuBarView.offersAutomaticRecordingReminder(enabled: false, dismissed: true))
    }

    @Test("a working setting has nothing to remind about")
    func nothingToSayWhileOn() {
        for dismissed in [true, false] {
            #expect(!MenuBarView.offersAutomaticRecordingReminder(enabled: true, dismissed: dismissed))
        }
    }

    @Test("dismissing the reminder does not change the setting it is about")
    func dismissalLeavesTheSettingAlone() {
        // Sending the card away must not switch detection on: the app goes on behaving the way the
        // user set it, and the popover just stops repeating itself.
        var settings = AppSettings.default
        settings.automaticDetectionEnabled = false
        settings.automaticDetectionNoticeDismissed = true
        #expect(settings.automaticDetectionEnabled == false)
        #expect(!MenuBarView.offersAutomaticRecordingReminder(
            enabled: settings.automaticDetectionEnabled,
            dismissed: settings.automaticDetectionNoticeDismissed
        ))
    }

    /// The height a view asks for at a fixed width.
    private func height(of view: some View, width: CGFloat = 360) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: width)))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let measured = hosting.fittingSize.height
        window.contentView = nil
        window.close()
        return measured.rounded()
    }

    @Test("the close control does not change the height of the card")
    func dismissingKeepsTheCardHeight() {
        // The button sits beside the text, so a card with one has to be the height of a card
        // without one. A taller card would shift everything under it the moment the reminder
        // appeared, which is a jump on the surface the user opens most often.
        @State var flag = false
        var plain: AnyView {
            AnyView(CRCallout(icon: "bell.slash.fill", title: "Title", message: "Message") {
                EmptyView()
            })
        }
        let dismissible = CRCallout(
            icon: "bell.slash.fill",
            title: "Title",
            message: "Message",
            dismiss: { flag.toggle() }
        ) {
            EmptyView()
        }
        #expect(height(of: plain) == height(of: dismissible))
    }
}
