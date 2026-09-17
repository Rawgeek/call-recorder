import AppKit
import Testing
@testable import CallRecorderApp

@Suite("Window presentation")
struct WindowPresentationTests {
    @MainActor
    @Test("visible windows promote the accessory app to a regular app")
    func policyPromotesForVisibleWindows() {
        #expect(WindowPresentation.activationPolicy(hasVisibleWindows: true) == .regular)
        #expect(WindowPresentation.activationPolicy(hasVisibleWindows: false) == .accessory)
    }

    @MainActor
    @Test("promotion happens before the window opens")
    func promotionPrecedesOpening() {
        var events: [String] = []

        WindowPresentation.present(
            open: { events.append("open") },
            activate: { events.append("activate") },
            promote: { events.append("promote") }
        )

        #expect(events.count >= 3)
        #expect(events[0] == "promote")
        #expect(events[1] == "activate")
        #expect(events[2] == "open")
    }

    @MainActor
    @Test("the borderless menu bar popover never keeps the app promoted")
    func borderlessPopoverDoesNotCount() {
        #expect(
            WindowPresentation.keepsAppPromoted(styleMask: [.borderless], isVisible: true) == false
        )
        #expect(
            WindowPresentation.keepsAppPromoted(styleMask: [.titled, .closable], isVisible: true) == true
        )
        #expect(
            WindowPresentation.keepsAppPromoted(styleMask: [.titled], isVisible: false) == false
        )
        #expect(WindowPresentation.presentationCounts([]) == false)
    }
}
