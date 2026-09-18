import CallRecorderCore
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsPane(
            title: "General",
            subtitle: "How Call Recorder starts, what it records, and where it saves."
        ) {
            CRSettingsCard(
                title: "Startup",
                footnote: model.settings.automaticDetectionEnabled
                    ? nil
                    : "With automatic recording off, nothing is captured until you press Start."
            ) {
                CRSettingsRow(title: "Start Call Recorder at login") {
                    Toggle("", isOn: $model.startAtLoginEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Record calls automatically",
                    detail: model.settings.automaticDetectionEnabled
                        ? "Starts when another app opens the microphone, stops shortly after it closes."
                        : "Off. Use the menu bar to start and stop."
                ) {
                    Toggle("", isOn: $model.settings.automaticDetectionEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            CRSettingsCard(
                title: "Automatic recording",
                footnote: "These apply to recordings the app starts by itself. Anything you start "
                    + "and stop by hand is kept and transcribed whatever it holds."
            ) {
                CRSettingsRow(
                    title: "Leave out apps that are not calls",
                    detail: model.settings.ignoresNonCallApps
                        ? "The voice recorder, dictation and the assistant never start a recording."
                        : "Any app that opens the microphone starts a recording.",
                    info: "More than meetings open the microphone. A voice memo, a dictation, and "
                        + "the system assistant all take it, and each of them used to start a call "
                        + "that had to be discarded. The list is short on purpose: an app that is "
                        + "not on it starts a recording, which costs one click to stop, while an "
                        + "app wrongly on it loses a meeting."
                ) {
                    Toggle("", isOn: $model.settings.ignoresNonCallApps)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                CRSettingsDivider()
                AutomaticRailRow(
                    title: "Discard recordings shorter than",
                    detail: model.settings.minimumAutomaticRecordingSeconds == 0
                        ? "Off. Every recording is transcribed, however short."
                        : "A shorter recording goes to Recently Deleted instead of being transcribed.",
                    info: "An app that opens the microphone for a second — a device check, a "
                        + "notification, a test — used to cost a full transcription and a row in "
                        + "the library. A recording that short is moved to Recently Deleted, where "
                        + "it stays for a day and can be put back.",
                    value: $model.settings.minimumAutomaticRecordingSeconds,
                    range: 0...300,
                    step: 15,
                    labelWidth: 44,
                    switchWrites: AutomaticRecordingRails.floorForSwitch
                ) { seconds in
                    seconds == 0 ? "Off" : String(Int(seconds.rounded())) + " s"
                }
                CRSettingsDivider()
                AutomaticRailRow(
                    title: "Stop automatically after",
                    detail: model.settings.maximumAutomaticRecordingMinutes == 0
                        ? "Off. A recording runs until the call app lets the microphone go."
                        : "A recording still running at the limit is stopped and kept.",
                    info: "A call app can hold the microphone open after the meeting ends, and a "
                        + "recorder that stops only when the microphone goes quiet records an empty "
                        + "room. One recorded fifteen hours that way. The limit counts recorded "
                        + "time, so a call paused for an hour is judged by what it holds.",
                    value: $model.settings.maximumAutomaticRecordingMinutes,
                    range: 0...600,
                    step: 30,
                    labelWidth: 64,
                    switchWrites: AutomaticRecordingRails.ceilingForSwitch
                ) { minutes in
                    minutes == 0 ? "Off" : String(Int(minutes.rounded())) + " min"
                }
                CRSettingsDivider()
                AutomaticRailRow(
                    title: "Stop after silence",
                    detail: model.settings.silenceStopMinutes == 0
                        ? "Off. A recording runs while both tracks are quiet."
                        : "Both tracks stay quieter than speech for this long, and the recording stops.",
                    info: "A meeting that ended can leave its app holding the microphone, and the "
                        + "recording then holds an empty room. Speech is measured at -50 dBFS, "
                        + "where zero is the loudest a sample can be: the room tone of a quiet room "
                        + "sits around -66 and speech reaches -40 and above. The rule asks for a "
                        + "long silence, it never applies to a recording you started by hand, and "
                        + "it does nothing at all when the level cannot be measured, because "
                        + "stopping a call that could not be heard is the one failure it must not "
                        + "have.",
                    value: $model.settings.silenceStopMinutes,
                    range: 0...120,
                    step: 5,
                    labelWidth: 48,
                    switchWrites: AutomaticRecordingRails.silenceForSwitch
                ) { minutes in
                    minutes == 0 ? "Off" : String(Int(minutes.rounded())) + " min"
                }
            }

            CRSettingsCard(
                title: "Recording",
                footnote: "A headset's microphone drops to call quality while it is in use, so the built-in microphone usually records a meeting better."
            ) {
                CRSettingsRow(
                    title: "Microphone",
                    detail: microphoneHint,
                    warning: microphoneHintIsWarning
                ) {
                    Picker("", selection: $model.selectedMicrophoneID) {
                        ForEach(model.microphoneChoices) { microphone in
                            Text(choiceName(microphone)).tag(microphone.id)
                        }
                    }
                    .labelsHidden()
                    // Trailing so the menu ends on the row's gutter whatever the device name is.
                    // Centred in the cap, a short name sat well inside the edge that the switch
                    // rows above it end on.
                    .frame(maxWidth: 260, alignment: .trailing)
                    .disabled(
                        model.availableMicrophones.isEmpty
                            || model.recorderState.phase == .recording
                            || model.recorderState.phase == .paused
                    )
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Record when there is no microphone",
                    detail: model.settings.recordsWithoutMicrophone
                        ? "A Mac with no audio input still records the other side of the call."
                        : "A recording with no microphone is refused until an input device appears.",
                    info: "A Mac mini has no audio input at all, and a recorder that insists on one "
                        + "records nothing there. ScreenCaptureKit captures the call's system audio "
                        + "on its own, so the other side is recorded and the transcript holds it. "
                        + "Turning this off keeps the refusal, which is the choice for a Mac that "
                        + "has a microphone and wants every recording to hold both sides."
                ) {
                    Toggle("", isOn: $model.settings.recordsWithoutMicrophone)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Keep recording after a call ends",
                    detail: "Extra time captured after the other app releases the microphone."
                ) {
                    Stepper(
                        value: $model.settings.automaticStopGraceSeconds,
                        in: 0...10,
                        step: 1
                    ) {
                        Text("\(model.settings.automaticStopGraceSeconds, specifier: "%.0f") s")
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Separate voices by the people on the call",
                    detail: model.settings.diarizationUsesParticipantCount
                        ? "The detector is told how many remote voices to find."
                        : "The detector decides how many voices the call holds.",
                    info: "The detector counts voices on its own, and on one long standup it counted "
                        + "one too many: fourteen remote voices came back as sixteen, and two of "
                        + "them had to be named with a name the transcript already used. Given the "
                        + "number it answers exactly that, in a third less time. The count is the "
                        + "people on the call less you, and it is used only when the recording held "
                        + "room for that many voices to have spoken. Turn this off if the people "
                        + "list is often incomplete: a count that is too low writes two people into "
                        + "one voice."
                ) {
                    Toggle("", isOn: $model.settings.diarizationUsesParticipantCount)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            CRSettingsCard(
                title: "After a call",
                footnote: "A brief is written on this Mac, by a model running on this Mac. "
                    + "Nothing about the call leaves it."
            ) {
                CRSettingsRow(
                    title: "Write a brief",
                    detail: briefDetail,
                    info: "A transcript is a record of everything that was said, which is the "
                        + "wrong shape for the question somebody asks later: what was this call "
                        + "about, and what am I to do about it? The brief answers that in under a "
                        + "hundred and fifty words, in the language the call was held in, and it "
                        + "is written from the finished transcript rather than while the call "
                        + "runs. It is the same text the MCP server hands to Codex, so a task "
                        + "that needs the call's context does not have to read the whole "
                        + "transcript to find it.",
                    warning: model.settings.summarizesCalls && model.briefReadiness != nil
                ) {
                    Toggle("", isOn: $model.settings.summarizesCalls)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            CRSettingsCard(
                title: "Storage",
                footnote: model.settings.removeAudioAfterTranscription
                    ? "Transcripts are written here. Audio is moved out of the way once the transcript and its search index are verified."
                    : "Transcripts are written here, and every recording keeps its audio beside them."
            ) {
                CRSettingsRow(title: "Recordings folder") {
                    HStack(spacing: CR.Space.inner) {
                        Text(abbreviatedPath)
                            .font(CR.Font.callout)
                            .foregroundStyle(CR.Ink.readable)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.settings.outputDirectory)
                        CRButton(title: "Reveal", icon: "folder") {
                            NSWorkspace.shared.selectFile(
                                nil,
                                inFileViewerRootedAtPath: model.settings.outputDirectory
                            )
                        }
                        CRButton(title: "Choose…", kind: .primary, action: chooseOutputDirectory)
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Remove the audio of a finished call",
                    detail: model.settings.removeAudioAfterTranscription
                        ? "Moved to Recently Deleted, where it stays for a day."
                        : "Every recording keeps its audio next to its transcript.",
                    info: "A finished call gives up its audio once the transcript and its search "
                        + "index are verified. The audio is kept in Recently Deleted for a day, so "
                        + "a transcript can still be checked against what was said, and a recording "
                        + "can be put back. Turning this off keeps the audio of every call, which "
                        + "costs the space the recordings take."
                ) {
                    Toggle("", isOn: $model.settings.removeAudioAfterTranscription)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            CRSettingsCard(
                title: "Updates",
                footnote: "Installed when Call Recorder quits or restarts, so the next launch is "
                    + "the new version."
            ) {
                CRSettingsRow(
                    title: "Version",
                    detail: updateDetail,
                    info: "Call Recorder follows its own repository for releases. A newer one is "
                        + "downloaded and checked while the app runs: the digest the release "
                        + "published, the identifier, the version, and the signature all have to "
                        + "match. The swap happens at the one moment the app is not using its "
                        + "bundle, which is when it quits. The version it replaced is kept, so a "
                        + "release that misbehaves can be put back."
                ) {
                    updateControls
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Install updates automatically",
                    detail: model.settings.automaticAppUpdatesEnabled
                        ? "A newer release is downloaded and checked, then installed at the next quit."
                        : "Checks still run; nothing is downloaded until it is asked for."
                ) {
                    HStack(spacing: CR.Space.inner) {
                        Toggle("", isOn: $model.settings.automaticAppUpdatesEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        CRButton(title: "Check Now") { model.appUpdater.checkNow() }
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Check for updates",
                    detail: "Runs at every launch, and on this step while the app stays open.",
                    info: "A check is one request to the release list. A shorter step notices a "
                        + "release sooner, and it costs nothing while there is no release: a "
                        + "download starts only when there is something newer than the copy that "
                        + "is running."
                ) {
                    Picker("", selection: $model.settings.appUpdateCheckInterval) {
                        ForEach(AppUpdateInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200, alignment: .trailing)
                }
                if let kept = model.appUpdater.keptVersion, kept != model.appUpdater.installedVersion {
                    CRSettingsDivider()
                    CRSettingsRow(
                        title: "Version " + kept + " is kept",
                        detail: "The copy from before the last automatic update. Going back stages "
                            + "it the way an update is staged."
                    ) {
                        CRButton(title: "Go Back") { model.appUpdater.rollBackToKeptVersion() }
                            .disabled(
                                model.appUpdater.pendingVersion != nil
                                    || model.appUpdater.state.isBusy
                            )
                    }
                }
            }
        }
    }

    /// Whether a call is being captured right now.
    ///
    /// A restart would end the call, and the audio of a call that is still being captured has not
    /// been finished into a file anything could put back. This is what holds the Restart button.
    private var isCapturing: Bool {
        model.recorderState.phase == .recording || model.recorderState.phase == .paused
    }

    /// What the app knows about its own version, in one sentence, plus anything it is doing.
    private var updateDetail: String {
        let updater = model.appUpdater
        let current = "Version " + updater.installedVersion + " (build "
            + String(updater.installedBuild) + ")."
        switch updater.state {
        case .idle:
            return current + " Not checked yet."
        case .checking:
            return current + " Checking…"
        case .upToDate:
            return current + " Up to date."
        case .available(let version):
            if updater.heldBackVersion == version {
                return current + " Version " + version
                    + " is available, and is not installed by itself because you went back."
            }
            return current + " Version " + version + " is available."
        case .downloading(let version):
            return current + " Downloading version " + version + "…"
        case .ready(let version):
            let waiting = updater.isRestoringOlderVersion ? "put back" : "installed"
            // A call being recorded is the one thing a restart would spoil, and the audio of a
            // call still being captured is not on disk in a form that could be put back.
            return isCapturing
                ? current + " Version " + version + " is " + waiting
                    + " when this recording ends, or at the next quit."
                : current + " Version " + version + " is " + waiting
                    + " when Call Recorder quits, or now if you press Restart."
        case .failed(let message):
            return message
        case .installByHand(let version, _):
            return "Version " + version
                + " cannot be installed by the app from here. Open the release page to do it yourself."
        }
    }

    @ViewBuilder
    private var updateControls: some View {
        let updater = model.appUpdater
        switch updater.state {
        case .idle:
            CRButton(title: "Check Now") { updater.checkNow() }
        case .checking:
            CRProgressRing(progress: nil)
        case .upToDate:
            CRStatusChip(tone: .ready, text: "Up to date")
        case .available(let version):
            HStack(spacing: CR.Space.inner) {
                CRStatusChip(tone: .waiting, text: version + " available")
                CRButton(title: "Download", kind: .primary) { updater.prepareOfferedUpdate() }
            }
        case .downloading:
            HStack(spacing: CR.Space.inner) {
                CRProgressRing(progress: updater.progress)
                if let progress = updater.progress {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(CR.Font.caption)
                        .monospacedDigit()
                        .foregroundStyle(CR.Ink.readable)
                        .frame(width: 30, alignment: .trailing)
                }
                CRButton(title: "Cancel") { updater.cancel() }
            }
        case .ready(let version):
            HStack(spacing: CR.Space.inner) {
                CRStatusChip(tone: .ready, text: version + " ready")
                CRButton(
                    title: "Restart",
                    icon: "arrow.clockwise",
                    kind: .primary,
                    help: isCapturing
                        ? "A call is being recorded, so the new version waits for this recording "
                            + "to end. It is installed the next time Call Recorder quits."
                        : "Installs " + version + " and opens Call Recorder again."
                ) {
                    updater.restartToApplyStaged()
                }
                // The row's other half is a sentence that wraps, and a wrapping sentence takes
                // width from whatever sits beside it: without this the button drew as "Rest…".
                .fixedSize()
                .disabled(isCapturing)
            }
        case .failed:
            HStack(spacing: CR.Space.inner) {
                // The sentence in the row says what went wrong, and the two things that land here
                // are a check that could not run and a restart that could not be arranged, so the
                // chip names neither of them on its own.
                CRStatusChip(tone: .failed, text: "Update failed")
                CRButton(title: "Try Again") { updater.checkNow() }
            }
        case .installByHand(_, let page):
            HStack(spacing: CR.Space.inner) {
                CRStatusChip(tone: .waiting, text: "Install by hand")
                CRButton(title: "Open Release Page") { NSWorkspace.shared.open(page) }
            }
        }
    }

    /// The name of a microphone choice. Only a real device carries the built-in label; the
    /// system choice names the device it points at instead.
    private func choiceName(_ choice: AudioInputDevice) -> String {
        choice.id == AudioCaptureSession.systemMicrophoneID
            ? choice.name
            : AudioCaptureSession.displayName(for: choice)
    }

    /// Shows the last two components of the path. The full path is one hover away, and the
    /// shortened form keeps the row on one line.
    private var abbreviatedPath: String {
        let components = model.settings.outputDirectory.split(separator: "/")
        if components.count <= 2 { return model.settings.outputDirectory }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private var selectedMicrophone: AudioInputDevice? {
        model.availableMicrophones.first { $0.id == model.selectedMicrophoneID }
    }

    /// Point out a Bluetooth headset, because its audio quality drops when it switches to call mode.
    private var microphoneHint: String {
        guard !model.availableMicrophones.isEmpty else {
            return model.settings.recordsWithoutMicrophone
                ? "No microphone available. Recordings will hold the other side only."
                : "No microphone available, and a recording without one is refused."
        }
        if model.selectedMicrophoneID == AudioCaptureSession.systemMicrophoneID {
            guard let systemMicrophone else { return "Follows the microphone macOS is set to use." }
            return "Follows the microphone macOS is set to use, which is " + systemMicrophone.name
                + " now."
        }
        guard let selectedMicrophone else { return "Used for new recordings" }
        return AudioCaptureSession.isBluetooth(selectedMicrophone)
            ? "Bluetooth headset selected. The built-in microphone usually sounds clearer."
            : "Used for new recordings"
    }

    private var microphoneHintIsWarning: Bool {
        // The warning follows the device the recording will actually use, so a system choice that
        // points at a headset warns about the headset rather than saying nothing.
        (model.selectedMicrophoneID == AudioCaptureSession.systemMicrophoneID
            ? systemMicrophone
            : selectedMicrophone)
            .map(AudioCaptureSession.isBluetooth) ?? false
    }

    /// The one line the brief setting says about itself.
    ///
    /// The three states are the three a person can act on: off, on with something missing, and on
    /// and ready. Which model writes the brief and where it is downloaded are the Models pane's
    /// business, so this points there rather than repeating it.
    private var briefDetail: String {
        guard model.settings.summarizesCalls else {
            return "Finished calls are not written up."
        }
        if let missing = model.briefReadiness {
            return (missing.errorDescription ?? "The brief model is not ready.") + " See Models."
        }
        return "Each finished call is written up in a short brief."
    }

    /// The device the system choice points at right now.
    private var systemMicrophone: AudioInputDevice? {
        guard let id = AudioCaptureSession.systemDefaultMicrophoneID() else { return nil }
        return model.availableMicrophones.first { $0.id == id }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.outputDirectory = url.path
        }
    }
}

/// One automatic-recording rail: a number beside a switch, and the two of them one setting.
///
/// The switch writes either zero or the standard the rule names, so a switch and the number beside
/// it cannot end up disagreeing about whether the rail is in force. The rails read the same way
/// because they are written once: the floor, the ceiling, and the silence limit differ in their
/// words, their range, and their rule, and in nothing else.
private struct AutomaticRailRow: View {
    let title: String
    let detail: String
    let info: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// The width the number needs, so that the switches of the card line up in one column.
    let labelWidth: CGFloat
    /// What the switch writes: the rule's standard while it is on, and zero while it is off.
    let switchWrites: (Bool) -> Double
    /// What the number reads, for the value it is given.
    let label: (Double) -> String

    var body: some View {
        CRSettingsRow(title: title, detail: detail, info: info) {
            HStack(spacing: CR.Space.inner) {
                // The number sits before the switch so that the switch is the last thing on every
                // row of the card.
                Stepper(value: $value, in: range, step: step) {
                    Text(label(value))
                        .monospacedDigit()
                        .frame(minWidth: labelWidth, alignment: .trailing)
                }
                .fixedSize()
                .disabled(value == 0)
                Toggle("", isOn: switchBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var switchBinding: Binding<Bool> {
        Binding(
            get: { value > 0 },
            set: { value = switchWrites($0) }
        )
    }
}
