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
                CRSettingsRow(
                    title: "Discard recordings shorter than",
                    detail: model.settings.minimumAutomaticRecordingSeconds == 0
                        ? "Off. Every recording is transcribed, however short."
                        : "A shorter recording goes to Recently Deleted instead of being transcribed.",
                    info: "An app that opens the microphone for a second — a device check, a "
                        + "notification, a test — used to cost a full transcription and a row in "
                        + "the library. A recording that short is moved to Recently Deleted, where "
                        + "it stays for a day and can be put back."
                ) {
                    HStack(spacing: CR.Space.inner) {
                        // The number sits before the switch so that the switch is the last thing on
                        // every row of the card, and the three of them line up in one column.
                        Stepper(
                            value: $model.settings.minimumAutomaticRecordingSeconds,
                            in: 0...300,
                            step: 15
                        ) {
                            Text(minimumRecordingText)
                                .monospacedDigit()
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                        .fixedSize()
                        .disabled(!discardsShortRecordings)
                        Toggle("", isOn: shortRecordingSwitch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
                CRSettingsDivider()
                CRSettingsRow(
                    title: "Stop automatically after",
                    detail: model.settings.maximumAutomaticRecordingMinutes == 0
                        ? "Off. A recording runs until the call app lets the microphone go."
                        : "A recording still running at the limit is stopped and kept.",
                    info: "A call app can hold the microphone open after the meeting ends, and a "
                        + "recorder that stops only when the microphone goes quiet records an empty "
                        + "room. One recorded fifteen hours that way. The limit counts recorded "
                        + "time, so a call paused for an hour is judged by what it holds."
                ) {
                    HStack(spacing: CR.Space.inner) {
                        Stepper(
                            value: $model.settings.maximumAutomaticRecordingMinutes,
                            in: 0...600,
                            step: 30
                        ) {
                            Text(maximumRecordingText)
                                .monospacedDigit()
                                .frame(minWidth: 64, alignment: .trailing)
                        }
                        .fixedSize()
                        .disabled(!stopsAtCeiling)
                        Toggle("", isOn: ceilingSwitch)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
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
                footnote: "Installed when Call Recorder quits, so the next launch is the new version."
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
                        ? "Checked at launch and every six hours."
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
            return updater.isRestoringOlderVersion
                ? current + " Version " + version + " is put back when Call Recorder quits."
                : current + " Version " + version + " is installed when Call Recorder quits."
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
            CRStatusChip(tone: .ready, text: version + " ready")
        case .failed:
            HStack(spacing: CR.Space.inner) {
                CRStatusChip(tone: .failed, text: "Check failed")
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

    /// The floor, as a person reads it: a number of seconds, or off.
    private var minimumRecordingText: String {
        let seconds = model.settings.minimumAutomaticRecordingSeconds
        return seconds == 0 ? "Off" : String(Int(seconds.rounded())) + " s"
    }

    /// The ceiling, as a person reads it: minutes, or off.
    private var maximumRecordingText: String {
        let minutes = model.settings.maximumAutomaticRecordingMinutes
        return minutes == 0 ? "Off" : String(Int(minutes.rounded())) + " min"
    }

    /// Whether the floor is in force.
    ///
    /// The rail has one setting rather than a switch beside a number, so a switch and its number
    /// cannot end up disagreeing about whether the rail is on. Zero is what the rules read as "not
    /// in force", and the switch writes either zero or the standard.
    private var discardsShortRecordings: Bool {
        model.settings.minimumAutomaticRecordingSeconds > 0
    }

    private var shortRecordingSwitch: Binding<Bool> {
        Binding(
            get: { discardsShortRecordings },
            set: {
                model.settings.minimumAutomaticRecordingSeconds =
                    AutomaticRecordingRails.floorForSwitch($0)
            }
        )
    }

    /// Whether the ceiling is in force, by the same rule.
    private var stopsAtCeiling: Bool {
        model.settings.maximumAutomaticRecordingMinutes > 0
    }

    private var ceilingSwitch: Binding<Bool> {
        Binding(
            get: { stopsAtCeiling },
            set: {
                model.settings.maximumAutomaticRecordingMinutes =
                    AutomaticRecordingRails.ceilingForSwitch($0)
            }
        )
    }

    private var selectedMicrophone: AudioInputDevice? {
        model.availableMicrophones.first { $0.id == model.selectedMicrophoneID }
    }

    /// Point out a Bluetooth headset, because its audio quality drops when it switches to call mode.
    private var microphoneHint: String {
        guard !model.availableMicrophones.isEmpty else { return "No microphone available" }
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
