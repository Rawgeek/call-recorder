import AppKit
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
    /// Whether the glyph is in the dimmed half of its blink.
    @State private var isDimmed = false

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .opacity(isDimmed ? 0.25 : 1)
            .accessibilityLabel("Call Recorder, \(model.statusLabel)")
            .onAppear {
                WindowPresentation.startObservingWindows()
            }
            // The phase is the identity: every change to it cancels whatever blink was running
            // and starts the one this state asks for, so no timer outlives the recording it was
            // announcing.
            .task(id: model.recorderState.phase) {
                await blink()
            }
    }

    /// Blinks while a recording runs, and stands still in every other state.
    private func blink() async {
        isDimmed = false
        guard
            MenuBarView.statusItemBlinks(
                phase: model.recorderState.phase,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(MenuBarView.blinkIntervalMilliseconds))
            guard !Task.isCancelled else { return }
            isDimmed.toggle()
        }
    }
}
