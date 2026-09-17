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
