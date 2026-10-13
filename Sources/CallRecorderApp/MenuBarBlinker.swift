import AppKit
import Foundation
import Observation

/// Keeps the menu bar icon blinking while the recorder runs.
///
/// The blink belongs to the model rather than to the label's own state, and that is the whole
/// point of this type: a menu bar label's appearance callbacks are not run when the app starts —
/// the note in `AppModel` says `onAppear` is not called until the menu is first drawn — so a timer
/// started there can sit still for the entire recording it was meant to announce. Changes to the
/// model do reach the label: the glyph itself already swaps when the phase changes, which is the
/// same channel this blink travels on.
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

    /// Read when a blink starts or stops rather than on every half, which is what the setting is
    /// for: the person it matters to sets it once and leaves it alone.
    @ObservationIgnored var reducesMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The wait between one half and the next. Injected so a test can pin the loop in place.
    @ObservationIgnored var sleep: (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }

    /// Starts, keeps, or stops the blink for the state the caller describes.
    ///
    /// Idempotent on purpose: the caller reports the recorder's state whenever it changes and
    /// whenever anything else does, and a second "yes" must not stack a second blink on the first.
    func update(shouldBlink: Bool) {
        guard shouldBlink, !reducesMotion() else {
            task?.cancel()
            task = nil
            isDimmed = false
            return
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.isDimmed.toggle()
                do {
                    try await self.sleep(.milliseconds(MenuBarView.blinkIntervalMilliseconds))
                } catch {
                    return
                }
            }
        }
    }
}

