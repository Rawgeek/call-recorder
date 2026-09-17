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
                        ForEach(model.availableMicrophones) { microphone in
                            Text(AudioCaptureSession.displayName(for: microphone)).tag(microphone.id)
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
                footnote: "Transcripts are written here. Audio is removed once the transcript and its search index are verified."
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
            }
        }
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
        guard let selectedMicrophone else { return "Used for new recordings" }
        return AudioCaptureSession.isBluetooth(selectedMicrophone)
            ? "Bluetooth headset selected. The built-in microphone usually sounds clearer."
            : "Used for new recordings"
    }

    private var microphoneHintIsWarning: Bool {
        selectedMicrophone.map(AudioCaptureSession.isBluetooth) ?? false
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
