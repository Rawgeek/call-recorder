import AppKit
import CallRecorderCore
import SwiftUI

/// A window the renderer needs to take the keyboard.
///
/// SwiftUI decides how to draw a switch by asking whether its window is key. The renderer's window
/// is off screen and has no title bar, so it could never become key on its own, and every switch
/// it drew came out in the off position. This renames that one rule and nothing else: it takes the
/// keyboard when asked, and it still never reaches the screen or the user's focus, because it is
/// never ordered in.
final class KeyableSnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// One recorder state worth a render.
///
/// A layout review needs the states a user actually meets, not only the empty one. These are the
/// phases the popover draws differently.
enum PreviewRecorderState: String, CaseIterable {
    case idle
    case recording
    case paused
    case awaitingParticipants
    case transcribing
    case indexing
    case failed

    var snapshotName: String { "menu-bar-\(rawValue)" }

    /// The reducer events that reach this state from idle, so the render never invents a state
    /// the app cannot be in.
    var events: [RecorderEvent] {
        let session = SessionID(rawValue: UUID())
        switch self {
        case .idle:
            return []
        case .recording:
            return [.manualStart(sessionID: session)]
        case .paused:
            return [.manualStart(sessionID: session), .manualPause]
        case .awaitingParticipants:
            return [.restorePendingSession(sessionID: session)]
        case .transcribing:
            return [.restorePendingSession(sessionID: session), .participantsSaved]
        case .indexing:
            return [
                .restorePendingSession(sessionID: session), .participantsSaved,
                .transcriptionFinished,
            ]
        case .failed:
            return [
                .manualStart(sessionID: session),
                .fail(.storageUnavailable),
            ]
        }
    }

    var showsElapsedTime: Bool { self == .recording || self == .paused }

    var failureMessage: String? {
        self == .failed ? "The recording could not be saved." : nil
    }
}

/// Renders the app's windows to PNG files without launching the interface.
///
/// Reviewing a layout change used to mean packaging the app, signing it (which needs an unlocked
/// keychain and a password), installing it, and relaunching. This runs the real views against the
/// real database and writes pictures instead, so a design can be checked in seconds, by anyone,
/// at any time. It never shows a window, never records, and never writes to the database.
@MainActor
enum SnapshotRunner {
    /// Runs the renderer when the environment asks for it.
    ///
    /// - Returns: true when a snapshot run happened, so the caller must not start the app.
    static func runIfRequested() -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["CALL_RECORDER_SNAPSHOT"],
              !directory.isEmpty
        else { return false }
        // A render must never reach the login keychain. The supported way to start one sets this
        // flag, and starting the binary by hand did not, so the run stopped on a keychain prompt
        // that nobody had asked for and the picture never arrived. Setting it here means the flag
        // no longer depends on how the process was started.
        setenv("CALL_RECORDER_PREVIEW", "1", 1)
        run(into: URL(filePath: directory, directoryHint: .isDirectory))
        return true
    }

    private static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // An accessory app has no dock icon and takes no focus, which is what a headless render
        // needs. The activation policy must be set before any window exists.
        NSApplication.shared.setActivationPolicy(.accessory)
        // Match the appearance the app is used in, so a render shows the same colours as the
        // running window instead of the system default.
        NSApplication.shared.appearance = previewAppearance
        let model = AppModel()
        // The model loads its metadata on a detached task, so the first render used to run
        // against an empty database and show "No recordings yet" over a full history. Wait for
        // the load to finish before drawing anything, so a picture of a pane is a picture of
        // the real data. The wait is bounded: a render must never hang.
        waitForMetadata(model)
        // A picture that leaves this machine is drawn from an invented library: the release
        // renderer asks for one, so the README cannot carry anybody's call history.
        if ProcessInfo.processInfo.environment["CALL_RECORDER_PREVIEW_SEED"] == "1" {
            model.seedPreviewLibrary()
        }

        // The popover is the surface the user opens most often, and it looks different in every
        // state. Rendering only the idle one left the recording, paused, and error layouts
        // unchecked, which are exactly the ones a user sees when something has gone wrong.
        // Each state is reached by replaying the app's own state machine, so a render shows the
        // layout the reducer produces rather than one assembled for the picture.
        for state in PreviewRecorderState.allCases {
            model.enterPreviewRecorderState(state)
            render(
                MenuBarView(model: model),
                size: CGSize(width: 360, height: 560),
                name: state.snapshotName,
                fittingHeight: true,
                into: directory
            )
        }
        model.enterPreviewRecorderState(.idle)
        if ProcessInfo.processInfo.environment["CALL_RECORDER_SPEAKER_BACKLOG"] == "1" {
            model.seedPreviewSpeakerIssue()
            render(
                MenuBarView(model: model),
                size: CGSize(width: 360, height: 560),
                name: "menu-bar-speaker-backlog",
                fittingHeight: true,
                into: directory
            )
            waitForMetadata(model)
            model.enterPreviewRecorderState(.idle)
        }
        // The first screen of a new install. It is drawn last of the popover states and the model
        // is put back afterwards, because it is the one render that has to hide the library.
        if ProcessInfo.processInfo.environment["CALL_RECORDER_REPEATED_ROWS"] == "1" {
            model.seedPreviewRepeatedRows()
            render(
                MenuBarView(model: model),
                size: CGSize(width: 360, height: 560),
                name: "menu-bar-repeated-rows",
                fittingHeight: true,
                into: directory
            )
            waitForMetadata(model)
            model.enterPreviewRecorderState(.idle)
        }
        // The row highlight, which no other render can show: it appears under the pointer, and a
        // pointer is the one thing an off-screen window does not have.
        if ProcessInfo.processInfo.environment["CALL_RECORDER_HOVERED_ROW"] == "1" {
            model.previewHoveredCallID = model.recentCalls.first?.id
            render(
                MenuBarView(model: model),
                size: CGSize(width: 360, height: 560),
                name: "menu-bar-hovered-row",
                fittingHeight: true,
                into: directory
            )
            model.previewHoveredCallID = nil
        }
        // A stage the user stopped, and the row whose work can be ended. Neither state exists
        // without a process that is running or has just ended, so the renderer names the call.
        if ProcessInfo.processInfo.environment["CALL_RECORDER_STOPPED_STAGE"] == "1",
            let newest = model.recentCalls.first?.id {
            model.previewStoppableCallID = newest
            model.previewStoppedProcessingCallID = newest
            render(
                MenuBarView(model: model),
                size: CGSize(width: 360, height: 560),
                name: "menu-bar-stopped-stage",
                fittingHeight: true,
                into: directory
            )
            model.previewStoppableCallID = nil
            model.previewStoppedProcessingCallID = nil
        }
        // A call that lost the other side of its conversation. The row carries a warning chip, and
        // no render may write that state into the library to get it.
        if ProcessInfo.processInfo.environment["CALL_RECORDER_MISSING_OTHER_SIDE"] == "1",
            let newest = model.recentCalls.first?.id {
            model.previewSystemAudioCallID = newest
            render(
                MenuBarView(model: model),
                size: CGSize(width: 360, height: 560),
                name: "menu-bar-missing-other-side",
                fittingHeight: true,
                into: directory
            )
            model.previewSystemAudioCallID = nil
        }
        if ProcessInfo.processInfo.environment["CALL_RECORDER_EMPTY_LIBRARY"] == "1" {
            model.clearLibraryForPreview()
            render(
                MenuBarView(model: model),
                size: CGSize(width: 360, height: 560),
                name: "menu-bar-first-launch",
                fittingHeight: true,
                into: directory
            )
            waitForMetadata(model)
        }
        // The whole Settings window, once per pane. Rendering a pane alone hid the sidebar,
        // which is most of what the window looks like and how someone navigates it. The size is
        // the size the window opens at, so a render shows the margins of a first open rather
        // than a size that was convenient. The window can be resized and a wide pane is where a
        // margin breaks, so CALL_RECORDER_SNAPSHOT_SIZE=1600x800 renders it at another size.
        let settingsSize = requestedSize() ?? CGSize(width: 880, height: 720)
        for section in SettingsSection.allCases {
            renderWindow(
                model: model,
                section: section,
                size: settingsSize,
                name: "settings-\(section.rawValue)",
                into: directory
            )
        }
        // A download in flight. The ring that fills is drawn from a byte count, and a render has
        // no transfer to count: without this the one state that answers "how long will this take"
        // is the one state that cannot be looked at.
        if let fraction = ProcessInfo.processInfo.environment["CALL_RECORDER_DOWNLOAD_PREVIEW"]
            .flatMap(Double.init) {
            model.modelManager.enterPreviewDownloading("large-v3-turbo", fraction: fraction)
            renderWindow(
                model: model,
                section: .models,
                size: settingsSize,
                name: "settings-models-downloading",
                into: directory
            )
            model.modelManager.leavePreviewDownloading()
        }
        // A version checked and waiting to be installed. Its row is the only place the Restart
        // button exists, and a render cannot reach the state on its own: the download that produces
        // it happens after the point preview mode stops at.
        if let version = ProcessInfo.processInfo.environment["CALL_RECORDER_UPDATE_READY"],
            !version.isEmpty
        {
            model.appUpdater.enterPreviewStaged(version)
            renderWindow(
                model: model,
                section: .general,
                size: settingsSize,
                name: "settings-general-update-ready",
                into: directory
            )
            model.appUpdater.leavePreviewStaged()
        }
        // The window checks the speaker runtime when it opens, which takes a few seconds. Drawing
        // while that ran caught the chip reading "Checking setup…", so two renders of the same
        // window could disagree. Run the check first and draw the settled state.
        settleSpeakerRuntime(model)
        render(SpeakerReviewView(model: model), size: CGSize(width: 760, height: 620), name: "speaker-review", into: directory)
        // One excerpt already moved onto somebody else. The state is written by the app into the
        // database and read back, so it cannot be reached by a render on its own; the seed says
        // what the card looks like once it has been used, and changes nothing on disk.
        if ProcessInfo.processInfo.environment["CALL_RECORDER_MOVED_LINES"] == "1" {
            settle { await model.seedPreviewReviewCard() }
            render(
                SpeakerReviewView(model: model),
                size: CGSize(width: 760, height: 620),
                name: "speaker-review-moved",
                into: directory
            )
        }
        // The participant picker is a window of its own, and the list is the control. It was the
        // only surface with no render, which is why its spacing was never checked.
        //
        // The window is opened here the way the real one opens: on a finished call, with that
        // call's people already checked. Rendering it with an empty selection drew a state the
        // window cannot reach through that path, and it hid where the checked rows land in the
        // list. Nothing is written: the selection is in memory and the render never saves.
        if let editingCallID = model.recentCalls.first?.id {
            model.selectedParticipantIDs = Set(
                (model.callParticipants[editingCallID] ?? []).map(\.id)
            )
        }
        render(
            ParticipantView(model: model, callID: model.recentCalls.first?.id),
            // The size the Participants window opens at, so a render shows the layout the user
            // gets rather than a roomier one they have to drag the corner to reach.
            size: CGSize(width: 640, height: 620),
            name: "participant-picker",
            into: directory
        )
        // The editors are sheets, so they are not reachable from a pane render. They were
        // rebuilt with the same components as the panes, so they are rendered the same way.
        //
        // Each is rendered at the size its own body declares. A larger frame centres the view and
        // adds a margin that is not in the layout, which reads as an padding mistake in the
        // picture and is not one.
        render(
            ParticipantEditor(model: model, participant: model.participants.first),
            size: CGSize(width: 440, height: 540),
            name: "editor-participant",
            into: directory
        )
        // The add sheet carries a name in with it, whether it came from the toolbar or from the
        // row under the list. It is rendered on its own because the prefill is the whole point:
        // the fields start empty and the name arrives already typed.
        render(
            ParticipantEditor(model: model, adding: "Nadia Rahimi"),
            size: CGSize(width: 440, height: 540),
            name: "editor-participant-add",
            into: directory
        )
        // What the participant picker opens onto. A popover does not draw off screen, so the list
        // itself is rendered: it is the part that has to be read, and it is rendered with a name
        // half typed so the picture shows both answers the field offers — the people who match,
        // and the row that makes somebody new.
        let onCall = Array(model.participants.prefix(3))
        render(
            ParticipantPickerList(
                participants: SpeakerReviewCandidates.ordered(
                    participants: model.participants,
                    onCall: onCall
                ),
                query: .constant("na"),
                onSelect: { _ in },
                create: { _ in nil },
                note: { participant in
                    onCall.contains(participant) ? "on this call" : nil
                }
            ),
            size: CGSize(width: 320, height: 300),
            name: "participant-picker-list",
            into: directory
        )
        render(
            GlossaryTermEditor(
                model: model,
                term: GlossaryTerm(
                    id: GlossaryTermID(rawValue: UUID()),
                    preferred: "Globex",
                    aliases: ["Globexx", "Globe X", "Globe-X"]
                )
            ),
            size: CGSize(width: 440, height: 400),
            name: "editor-term",
            into: directory
        )
        // The components on their own page. A control that is a different height from the one
        // beside it is easy to miss in a pane and obvious here.
        render(
            DesignSystemSheet(),
            size: CGSize(width: 940, height: 560),
            name: "design-system",
            fittingHeight: true,
            into: directory
        )
        print("snapshots written to \(directory.path)")
    }

    /// The size the settings panes should be rendered at, when the environment names one.
    private static func requestedSize() -> CGSize? {
        guard let raw = ProcessInfo.processInfo.environment["CALL_RECORDER_SNAPSHOT_SIZE"] else {
            return nil
        }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else {
            print("snapshot: CALL_RECORDER_SNAPSHOT_SIZE is not WIDTHxHEIGHT, using the default")
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// The appearance a render is drawn in.
    ///
    /// The app follows the system appearance, and only the dark one had ever been looked at.
    /// Every colour here is a light or dark system colour with an opacity over it, so the two
    /// appearances are not mirror images: a fill that reads as a card on a dark window can
    /// disappear on a light one. The two environment variables make the other appearance, and
    /// the Increase Contrast appearance, renderable, so a claim about them can be checked.
    ///
    ///     CALL_RECORDER_APPEARANCE=light scripts/preview.sh
    ///     CALL_RECORDER_APPEARANCE=light CALL_RECORDER_CONTRAST=high scripts/preview.sh
    private static var previewAppearance: NSAppearance {
        let environment = ProcessInfo.processInfo.environment
        let isLight = environment["CALL_RECORDER_APPEARANCE"]?.lowercased() == "light"
        let isHighContrast = environment["CALL_RECORDER_CONTRAST"]?.lowercased() == "high"
        let name: NSAppearance.Name
        switch (isLight, isHighContrast) {
        case (false, false): name = .darkAqua
        case (true, false): name = .aqua
        case (false, true): name = .accessibilityHighContrastDarkAqua
        case (true, true): name = .accessibilityHighContrastAqua
        }
        // The name is a system constant, so this only falls back if a future system drops one.
        return NSAppearance(named: name) ?? NSAppearance(named: .darkAqua)!
    }

    /// Spins the run loop until the model has read the database, or the deadline passes.
    ///
    /// The run loop has to turn for the loading task to make progress. Waiting on a single
    /// field was the first attempt and it drew the menu bar too early, because that field is
    /// assigned partway through the read. This waits for the read to finish.
    /// Runs an async step to completion, for the parts of a render that read the database.
    ///
    /// The renderer is a synchronous command-line path that pumps a run loop, so an async call
    /// cannot simply be awaited in it. This runs the work on the main actor and turns the run loop
    /// until it finishes, which is the same thing the app itself is doing at that moment.
    private static func settle(_ work: @escaping @MainActor () async -> Void, timeout: TimeInterval = 30) {
        var done = false
        Task { @MainActor in
            await work()
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if !done { print("snapshot: a seed step did not finish within \(Int(timeout))s") }
    }

    private static func waitForMetadata(_ model: AppModel, timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if model.metadataIsLoaded { return }
        }
        print("snapshot: metadata did not load within \(Int(timeout))s; rendering an empty state")
    }

    /// Runs the speaker runtime check, and waits for it, before the speaker window is drawn.
    ///
    /// The check loads a local model and takes a few seconds. A render that started while it ran
    /// drew the middle of it, which is neither the state a person sees when they open the window
    /// nor a stable picture to compare against. The wait is bounded: a render must never hang.
    private static func settleSpeakerRuntime(_ model: AppModel, timeout: TimeInterval = 90) {
        guard model.speakerRuntimeMessage == "Speaker setup has not been checked." else { return }
        Task { await model.checkSpeakerRuntime() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if model.speakerRuntimeMessage != "Speaker setup has not been checked." { return }
        }
        print("snapshot: the speaker runtime check did not finish within \(Int(timeout))s")
    }

    /// Draws one view at a fixed size and writes it as a PNG.
    ///
    /// The view is pinned to the top. A view shorter than the frame is centred by default, which
    /// put a margin above the popover that the popover does not have and moved it up and down
    /// between states, so two renders of the same surface could not be compared.
    /// Draws one view and writes it as a PNG.
    ///
    /// A popover has no fixed height: the system sizes it to its content. Passing a height for it
    /// put empty space under the last row that the real popover does not have, and made two states
    /// look different lengths when they are not. When `fittingHeight` is set the view measures
    /// itself first and the frame is built from that measurement, exactly as the system does it.
    private static func render(
        _ view: some View,
        size: CGSize,
        name: String,
        fittingHeight: Bool = false,
        into directory: URL
    ) {
        let size = fittingHeight ? CGSize(width: size.width, height: measuredHeight(of: view, width: size.width)) : size
        let frame = NSRect(origin: .zero, size: size)
        // The panes draw on a clear background, because in the running app the window supplies
        // one. An off-screen window supplies nothing, so capturing the view alone produced a
        // blank bitmap with invisible text. A container with a real background stands in for the
        // window and makes the render show what the user sees.
        let container = NSView(frame: frame)
        container.wantsLayer = true
        container.appearance = previewAppearance
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let hosting = NSHostingView(
            rootView: AnyView(view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        )
        hosting.frame = frame
        hosting.appearance = previewAppearance
        container.addSubview(hosting)

        // A borderless off-screen window gives the view a real backing store. Without one, the
        // controls that draw through AppKit render blank.
        //
        // It must also accept the keyboard. A switch asks whether its window is key before it
        // draws its accent, and a window that never becomes key draws every switch as though it
        // were off. Every render therefore showed an unchanged switch on every card, whatever the
        // real setting was, so the picture could not be used to check the state of a setting and
        // a pane that had lost its switch state would have looked correct. Measured on a probe
        // window: zero accent pixels without the keyboard, and the accent drawn once it is taken.
        let window = KeyableSnapshotWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = previewAppearance
        window.contentView = container
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        // The run loop must turn once for SwiftUI to lay out and for materials to resolve.
        //
        // The keyboard is taken before the run loop turns, so a switch draws the state it is in
        // rather than looking switched off in every picture. Only becoming key does this: asking a
        // window to make itself key on an inactive accessory app changes nothing, which was
        // measured on a probe window. The window is never ordered in, so this takes no focus from
        // the user.
        _ = window.becomeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            print("snapshot \(name): no bitmap")
            return
        }
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("snapshot \(name): no png")
            return
        }
        let url = directory.appending(path: "\(name).png")
        do {
            try data.write(to: url)
            print("snapshot \(name) \(Int(size.width))x\(Int(size.height))")
        } catch {
            print("snapshot \(name) failed: \(error.localizedDescription)")
        }
        window.contentView = nil
        window.close()
    }

    /// Draws the whole Settings window on one pane.
    ///
    /// The height a self-sizing view asks for, laid out at the given width. The view is measured
    /// in an off-screen window, because a measurement taken outside one is not the same as what
    /// the system draws.
    private static func measuredHeight(of view: some View, width: CGFloat) -> CGFloat {
        let probe = NSHostingView(
            rootView: AnyView(view.frame(width: width, alignment: .top))
        )
        probe.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        // Measured in a window that can take the keyboard for the same reason the render is: a
        // switch asks for one before it draws its accent, and a measurement taken without it is
        // not the height the pane is drawn at.
        let window = KeyableSnapshotWindow(
            contentRect: probe.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = previewAppearance
        window.contentView = probe
        probe.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let height = probe.fittingSize.height
        window.contentView = nil
        window.close()
        return max(120, height.rounded(.up))
    }

    ///
    /// The pane is selected through the environment before the view is constructed, because the
    /// window reads it once when it appears. That is how a render shows the sidebar, the title
    /// bar, and the content in their real arrangement.
    ///
    /// Two renders are written for each pane. The first is the window at the size it opens, which
    /// is what the app looks like. The second is the same pane at the height its content asks for,
    /// which is what lets a check see the cards below the fold: Settings scrolls, so the bottom of
    /// a long pane was outside every measurement the audit could take. A card nobody could see was
    /// a card nobody could check.
    private static func renderWindow(
        model: AppModel,
        section: SettingsSection,
        size: CGSize,
        name: String,
        into directory: URL
    ) {
        setenv("CALL_RECORDER_SETTINGS_PANE", section.rawValue, 1)
        render(SettingsView(model: model), size: size, name: name, into: directory)
        let full = measuredHeight(of: SettingsView(model: model), width: size.width)
        if full > size.height {
            render(
                SettingsView(model: model),
                size: CGSize(width: size.width, height: full),
                name: name + "-full",
                into: directory
            )
        }
        unsetenv("CALL_RECORDER_SETTINGS_PANE")
    }
}

/// Runs the glossary repair from the command line instead of the settings window.
///
/// The same pass is a button in Recovery. It is also reachable here so a repair can be run, and
/// its result read, without a window on screen: work that rewrites saved files should be
/// runnable somewhere its output can be kept. The app must be quit first, because it holds the
/// database open and would re-index from the text it already has in memory.
///
/// `CALL_RECORDER_REPAIR_DRYRUN=1` counts what the pass would change and writes nothing, so a
/// repair over a whole library can be read before it is run.
@MainActor
enum RepairCommand {
    static func runIfRequested() async -> Bool {
        guard ProcessInfo.processInfo.environment["CALL_RECORDER_REPAIR_GLOSSARY"] == "1" else {
            return false
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        // Voice identity reads a key from the login keychain, which raises a system prompt on a
        // locked keychain. A text repair needs no voice profiles, and a recovery command that
        // stops to ask for a password is one that cannot be run unattended.
        setenv("CALL_RECORDER_PREVIEW", "1", 1)
        let model = AppModel()
        await model.waitForMetadata()
        let dryRun = ProcessInfo.processInfo.environment["CALL_RECORDER_REPAIR_DRYRUN"] == "1"
        await model.reapplyGlossaryToSavedTranscripts(dryRun: dryRun)
        print(model.recoveryMessage ?? "No result was reported.")
        // The one repair that removes files has its own switch, so it is never reached by asking
        // for the rewrite. A command that deletes something should have to be asked for by name.
        if ProcessInfo.processInfo.environment["CALL_RECORDER_REMOVE_EMPTY_TRANSCRIPTS"] == "1" {
            if let outcome = await model.removeTranscriptsWithNoSpeech(dryRun: dryRun) {
                print(
                    "empty transcript cleanup: examined \(outcome.examined), "
                        + "\(dryRun ? "would remove" : "removed") \(outcome.removed), "
                        + "failed \(outcome.failed)"
                )
            } else {
                print("empty transcript cleanup: the library could not be read")
            }
        }
        return true
    }
}

/// Decides whether this process renders snapshots, repairs transcripts, or runs the app.
///
/// These modes have to happen before any scene exists, which is why the entry point is explicit
/// rather than the synthesized one.
@main
enum Entry {
    static func main() {
        if SnapshotRunner.runIfRequested() { return }
        if ProcessInfo.processInfo.environment["CALL_RECORDER_REPAIR_GLOSSARY"] == "1" {
            // The repair is async and runs on the main actor, so the main thread must keep
            // turning the run loop for it to make progress. Blocking the thread on a semaphore
            // deadlocks the work it is waiting for.
            var finished = false
            Task {
                _ = await RepairCommand.runIfRequested()
                finished = true
            }
            while !finished {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return
        }
        CallRecorderApp.main()
    }
}
