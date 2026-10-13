import AppKit
import CallRecorderCore
import SwiftUI

struct CallRecorderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            StatusItemLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Participants", id: "participants") {
            ParticipantView(model: model)
        }
        // A window that opens smaller than its own content minimum clips the controls at the
        // edge, and the first thing to go is the label on the button the window exists for.
        .defaultSize(width: 640, height: 620)

        Window("Review Speakers", id: "speaker-review") {
            SpeakerReviewView(model: model)
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            SettingsView(model: model)
        }
        // The sidebar, the readable measure, and the pane's margins, with a little slack. The
        // window used to open 120 points wider than its content, which drew a hundred-point
        // empty column down each side of every pane. It can still be pulled wider; the pane
        // centres its column and keeps the measure.
        .defaultSize(width: 880, height: 720)
    }
}

private struct StatusItemLabel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: Self.symbol(for: model))
            .accessibilityLabel("Call Recorder, \(model.statusLabel)")
            .onAppear {
                WindowPresentation.startObservingWindows()
            }
    }

    /// Whether the icon moves: a recording runs, and the system has not asked for still.
    ///
    /// Reduce Motion is read when the label is drawn. The setting is one a person sets once; the
    /// glyph still says the state (a filled record circle while a recording runs).
    static func blinks(phase: RecordingPhase) -> Bool {
        MenuBarView.statusItemBlinks(
            phase: phase,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    /// The glyph the status item draws, which is the recorder's symbol half-way through a blink.
    ///
    /// The quiet half of the blink swaps the record circle's filling rather than its opacity,
    /// because that is what this surface renders: a menu bar item draws a template image, and a
    /// template is a shape. Half-transparent ink and opaque ink make the same shape, so an opacity
    /// step changes nothing on screen — measured on 2026-10-13, twelve frames a tenth of a second
    /// apart were byte identical while an opacity-driven blink ran, and the two versions of the
    /// record circle alternating at the same pace were the first frames that differed. A filled
    /// circle and an outlined one are different shapes, and the swap is what a person sees.
    static func symbol(for model: AppModel) -> String {
        guard blinks(phase: model.recorderState.phase), model.menuBarIconDimmed else {
            return model.menuBarSymbol
        }
        return "record.circle"
    }
}
