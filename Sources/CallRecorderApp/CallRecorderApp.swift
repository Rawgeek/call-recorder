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
        Image(nsImage: Self.icon(for: model))
            .accessibilityLabel("Call Recorder, \(model.statusLabel)")
            .onAppear {
                WindowPresentation.startObservingWindows()
            }
    }

    /// The glyph at this moment's ink: full strength while nothing is captured, and the pulse's
    /// two grays while a recording runs.
    ///
    /// The pulse is two grays rather than a black and a gap: the person asked for it softer on
    /// 2026-10-13 — "не из прозрачного в черный, а из прозрачного в серый" — so the quiet half is
    /// a light gray and the loud half a medium one, and neither end is black. Reduce Motion keeps
    /// the glyph still, at full ink. The ink travels inside the image because a menu bar item
    /// drops an `opacity` modifier — measured on 2026-10-13, twenty frames a third of a second
    /// apart were byte identical while a modifier-driven pulse ran — and follows an image that is
    /// replaced.
    static func icon(for model: AppModel) -> NSImage {
        MenuBarView.statusItemIcon(
            name: model.menuBarSymbol,
            ink: MenuBarView.statusItemOpacity(
                phase: model.recorderState.phase,
                dimmed: model.menuBarIconDimmed,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        )
    }
}
