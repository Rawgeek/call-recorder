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

        Window("Live Transcript", id: "live-transcript") {
            LiveTranscriptView(model: model)
        }
        .defaultSize(width: 620, height: 640)

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
        Image(systemName: model.menuBarSymbol)
            .accessibilityLabel("Call Recorder, \(model.statusLabel)")
            .onAppear {
                WindowPresentation.startObservingWindows()
            }
            // The live window opens when a recording starts, and a model cannot open a window: the
            // count says that a recording began, and the surface that owns windows draws it. The
            // window is opened the way every other window here is opened, which is what puts it in
            // front of the meeting rather than behind it: an accessory app's window that is merely
            // ordered front stays behind whatever the person is looking at.
            .onChange(of: model.liveWindowToken) { _, token in
                guard token > 0 else { return }
                WindowPresentation.present(open: { openWindow(id: "live-transcript") })
            }
    }
}
