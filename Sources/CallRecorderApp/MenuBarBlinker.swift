import AppKit
import Foundation
import Observation
import OSLog

/// Keeps the menu bar icon blinking while the recorder runs.
///
/// The blink belongs to the model rather than to the label's own state, and that is the whole
/// point of this type: a menu bar label's appearance callbacks are not run when the app starts —
/// the note in `AppModel` says `onAppear` is not called until the menu is first drawn — so a timer
/// started there can sit still for the entire recording it was meant to announce.
///
/// Every half of the blink is reported to `onDim` as well as stored here. The label draws the
/// stored value, and the owner forwards the reported one onto its own observed property: a nested
/// object's change is not a change of the object that holds it, and the label listens to the holder.
///
/// Nothing here reads the clock: the wait is a property, so a test drives the loop without one.
@MainActor
@Observable
final class MenuBarBlinker {
    /// Whether the glyph is in the dimmed half of its blink.
    private(set) var isDimmed = false

    /// Whether a blink is running, so a test can tell a stopped one from a dimmed one.
    var isBlinking: Bool { task != nil }

    @ObservationIgnored private var task: Task<Void, Never>?

    /// Called with every half of the blink, so the owner can republish it where the label listens.
    @ObservationIgnored var onDim: ((Bool) -> Void)?

    /// Read when a blink starts or stops rather than on every half, which is what the setting is
    /// for: the person it matters to sets it once and leaves it alone.
    @ObservationIgnored var reducesMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The wait between one half and the next. Injected so a test can pin the loop in place.
    @ObservationIgnored var sleep: (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    @ObservationIgnored private let logger = Logger(
        subsystem: "local.callrecorder.app",
        category: "menu-bar"
    )

    /// Starts, keeps, or stops the blink for the state the caller describes.
    ///
    /// Idempotent on purpose: the caller reports the recorder's state whenever it changes and
    /// whenever anything else does, and a second "yes" must not stack a second blink on the first.
    func update(shouldBlink: Bool) {
        guard shouldBlink, !reducesMotion() else {
            let wasBlinking = task != nil
            task?.cancel()
            task = nil
            if isDimmed {
                isDimmed = false
                onDim?(false)
            }
            if wasBlinking || shouldBlink {
                logger.notice(
                    "menu bar blink stopped: shouldBlink=\(shouldBlink, privacy: .public) reduceMotion=\(self.reducesMotion(), privacy: .public)"
                )
            }
            return
        }
        guard task == nil else { return }
        logger.notice("menu bar blink started at \(MenuBarView.blinkIntervalMilliseconds, privacy: .public) ms")
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let dimmed = !self.isDimmed
                self.isDimmed = dimmed
                self.onDim?(dimmed)
                do {
                    try await self.sleep(.milliseconds(MenuBarView.blinkIntervalMilliseconds))
                } catch {
                    return
                }
            }
        }
    }
}
